import json
import os
import queue
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import numpy as np
import pyvirtualcam
import sounddevice as sd
from zeroconf import ServiceInfo, Zeroconf

HOST = "0.0.0.0"
PORT = 55880
PKT_VIDEO = 1
PKT_AUDIO = 2
PKT_CONFIG = 3

def get_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()

def find_vb_cable_device():
    devices = sd.query_devices()
    for idx, d in enumerate(devices):
        if d["max_output_channels"] > 0 and "CABLE Input" in d["name"]:
            return idx, d["name"]
    return None, None

def register_bonjour(ip, port):
    try:
        zc = Zeroconf()
        info = ServiceInfo(
            "_camlink._tcp.local.",
            f"PC-Desktop._camlink._tcp.local.",
            addresses=[socket.inet_aton(ip)],
            port=port,
            properties={"version": "1.0"},
        )
        zc.register_service(info)
        return zc, info
    except Exception as e:
        print(f"[AVISO] Bonjour indisponivel ({e}) - conecte pelo IP {ip}")
        return None, None

class AudioRouter:
    def __init__(self):
        self.stream = None
        self.sample_rate = 48000
        self.channels = 1
        self.device_idx, self.device_name = find_vb_cable_device()
        if self.device_idx is not None:
            print(f"[AUDIO] Saida virtual encontrada: {self.device_name} (ID {self.device_idx})")
        else:
            print("[AUDIO] AVISO: VB-Cable nao detectado ainda! Instale o VB-Cable para ativar o microfone virtual.")

    def configure(self, sample_rate, channels):
        if self.device_idx is None:
            self.device_idx, self.device_name = find_vb_cable_device()
            if self.device_idx is None:
                return
        if self.stream and self.sample_rate == sample_rate and self.channels == channels:
            return
        self.close()
        self.sample_rate = sample_rate
        self.channels = channels
        try:
            self.stream = sd.RawOutputStream(
                samplerate=sample_rate,
                channels=channels,
                dtype="int16",
                device=self.device_idx,
                latency="low",
                blocksize=0,
            )
            self.stream.start()
            print(f"[AUDIO] Stream ativo -> {self.device_name} ({sample_rate} Hz, {channels}ch)")
        except Exception as e:
            print(f"[AUDIO] Erro ao abrir VB-Cable: {e}")

    def write(self, pcm_bytes):
        if self.stream is None:
            self.configure(self.sample_rate, self.channels)
        if self.stream is not None:
            try:
                self.stream.write(pcm_bytes)
            except Exception:
                pass

    def close(self):
        if self.stream is not None:
            try:
                self.stream.stop()
                self.stream.close()
            except Exception:
                pass
            self.stream = None

class VideoPipeline:
    def __init__(self, width=1080, height=1920, fps=30):
        self.width = width
        self.height = height
        self.fps = fps
        self.frame_bytes = width * height * 3 // 2  # NV12
        self.ffmpeg = None
        self.cam = None
        self.running = False
        self.reader_thread = None
        self.frames_count = 0

    def start(self):
        self.stop()
        ffmpeg_bin = shutil.which("ffmpeg")
        if not ffmpeg_bin:
            raise RuntimeError("ffmpeg nao encontrado no PATH.")

        self.cam = pyvirtualcam.Camera(
            width=self.width,
            height=self.height,
            fps=self.fps,
            fmt=pyvirtualcam.PixelFormat.NV12,
            backend="obs",
        )
        print(f"[VIDEO] OBS Virtual Camera ativa: {self.cam.device} ({self.width}x{self.height} @ {self.fps} FPS NV12)")

        cmd = [
            ffmpeg_bin,
            "-hide_banner", "-loglevel", "error",
            "-fflags", "nobuffer",
            "-flags", "low_delay",
            "-probesize", "32768",
            "-analyzeduration", "0",
            "-f", "h264",
            "-i", "pipe:0",
            "-f", "rawvideo",
            "-pix_fmt", "nv12",
            "-s", f"{self.width}x{self.height}",
            "pipe:1",
        ]
        self.ffmpeg = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self.running = True
        self.reader_thread = threading.Thread(target=self._read_loop, daemon=True)
        self.reader_thread.start()

    def _read_loop(self):
        out = self.ffmpeg.stdout
        need = self.frame_bytes
        while self.running:
            buf = bytearray()
            while len(buf) < need and self.running:
                chunk = out.read(need - len(buf))
                if not chunk:
                    self.running = False
                    return
                buf.extend(chunk)
            if len(buf) == need and self.cam is not None:
                frame = np.frombuffer(buf, dtype=np.uint8)
                self.cam.send(frame)
                self.frames_count += 1

    def feed_h264(self, data):
        if self.ffmpeg and self.ffmpeg.stdin and self.running:
            try:
                self.ffmpeg.stdin.write(data)
            except Exception:
                pass

    def stop(self):
        self.running = False
        if self.ffmpeg:
            try:
                self.ffmpeg.stdin.close()
                self.ffmpeg.terminate()
                self.ffmpeg.wait(timeout=2)
            except Exception:
                pass
            self.ffmpeg = None
        if self.cam:
            try:
                self.cam.close()
            except Exception:
                pass
            self.cam = None

def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf.extend(chunk)
    return bytes(buf)

def handle_client(conn, addr, video: VideoPipeline, audio: AudioRouter):
    print(f"\n[CONECTADO] iPhone conectado de {addr[0]}:{addr[1]}")
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    video.start()
    last_stat = time.time()
    bytes_in = 0
    try:
        while True:
            hdr = recv_exact(conn, 13)
            if not hdr:
                break
            pkt_type, ts_us, length = struct.unpack(">BQI", hdr)
            if length == 0 or length > 20_000_000:
                continue
            payload = recv_exact(conn, length)
            if not payload:
                break
            bytes_in += length

            if pkt_type == PKT_VIDEO:
                video.feed_h264(payload)
            elif pkt_type == PKT_AUDIO:
                audio.write(payload)
            elif pkt_type == PKT_CONFIG:
                cfg = json.loads(payload.decode("utf-8", errors="ignore"))
                print(f"[CONFIG] iPhone enviando: {cfg}")
                audio.configure(cfg.get("sampleRate", 48000), cfg.get("channels", 1))

            now = time.time()
            if now - last_stat >= 3.0:
                mbps = (bytes_in * 8) / ((now - last_stat) * 1_000_000)
                fps_real = video.frames_count / (now - last_stat)
                print(f"[STATUS] {fps_real:.1f} FPS | {mbps:.2f} Mbps | Audio: {audio.device_name or 'Sem VB-Cable'}")
                bytes_in = 0
                video.frames_count = 0
                last_stat = now
    except Exception as e:
        print(f"[DESCONECTADO] Motivo: {e}")
    finally:
        video.stop()
        audio.close()
        conn.close()
        print("[AGUARDANDO] Pronto para nova conexao do iPhone...")

def main():
    ip = get_local_ip()
    print("==============================================")
    print("   CamLinkNative - Receptor Windows (LAN)     ")
    print(f"   IP do seu PC: {ip}  |  Porta: {PORT}")
    print("==============================================")
    zc, info = register_bonjour(ip, PORT)
    audio = AudioRouter()
    video = VideoPipeline(width=1080, height=1920, fps=30)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(1)
    print(f"[AGUARDANDO] Abra o CamLinkNative no iPhone 15 e toque em TRANSMITIR...\n")

    try:
        while True:
            conn, addr = srv.accept()
            handle_client(conn, addr, video, audio)
    except KeyboardInterrupt:
        print("\nEncerrando CamLinkNative...")
    finally:
        if zc and info:
            zc.unregister_service(info)
            zc.close()
        srv.close()

if __name__ == "__main__":
    main()
