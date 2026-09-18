# Test the generated binaries

## Native Linux

```bash
FFMPEG="$HOME/build/build_ffmpeg/output/linux/bin/ffmpeg"
FFPROBE="$HOME/build/build_ffmpeg/output/linux/bin/ffprobe"
"$FFMPEG" -version
"$FFMPEG" -encoders | grep nvenc
"$FFMPEG" -h filter=whisper
"$FFMPEG" -f lavfi -i testsrc2=size=320x240:rate=25 -t 2 -c:v libx264 /tmp/cpu-test.mp4
"$FFPROBE" -show_streams /tmp/cpu-test.mp4
```

GPU video test, with a compatible NVIDIA driver installed:

```bash
"$FFMPEG" -f lavfi -i testsrc2=size=1280x720:rate=30 -t 5 -c:v h264_nvenc /tmp/gpu-test.mp4
"$FFMPEG" -hwaccel cuda -hwaccel_output_format cuda -i input.mp4 -c:v av1_nvenc -c:a copy output.mkv
```

## Windows PowerShell

Copy `ffmpeg.exe`, `ffprobe.exe`, `ffplay.exe` and required dependency DLLs from
the Windows output directory to Windows, then run from that folder:

```powershell
.\ffmpeg.exe -version
.\ffmpeg.exe -encoders | Select-String nvenc
.\ffmpeg.exe -hwaccels
.\ffmpeg.exe -f lavfi -i testsrc2=size=1280x720:rate=30 -t 5 -c:v h264_nvenc gpu-test.mp4
.\ffprobe.exe -show_streams gpu-test.mp4
.\ffmpeg.exe -hwaccel cuda -hwaccel_output_format cuda -i input.mp4 -c:v av1_nvenc -c:a copy output.mkv
```

NVIDIA NVENC/NVDEC video acceleration is independent of Whisper's Vulkan compute
backend. The `cuda` hardware-decoding option does not require a local CUDA toolkit
and does not mean CUDA NPP filters or CUDA Whisper are enabled.

## GPU Whisper transcription

Download a model separately. For English speech, the base English model is one
starting point; multilingual speech needs a multilingual model such as `ggml-base.bin`.

Linux:

```bash
mkdir -p "$HOME/build/build_ffmpeg/models"
cd "$HOME/build/build_ffmpeg"
curl -fL https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin -o models/ggml-base.en.bin
./output/linux/bin/ffmpeg -i speech.wav -af 'whisper=model=models/ggml-base.en.bin:language=en:use_gpu=1:gpu_device=0:destination=transcript.srt:format=srt' -f null -
```

Windows PowerShell:

```powershell
New-Item -ItemType Directory -Force models
Invoke-WebRequest -Uri 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin' -OutFile 'models/ggml-base.en.bin'
.\ffmpeg.exe -h filter=whisper
.\ffmpeg.exe -i speech.wav -af "whisper=model=models/ggml-base.en.bin:language=en:use_gpu=1:gpu_device=0:destination=transcript.srt:format=srt" -f null -
```

Use relative paths and forward slashes inside Windows filter arguments to avoid
escaping drive-letter colons. Adjust `gpu_device` based on the Vulkan device list
in the log. `use_gpu=1` requests GPU processing; inspect the log to confirm the
intended GPU was selected and processing did not fall back to CPU. Use
`use_gpu=0` to explicitly test CPU transcription.

No model is bundled in the Git repository or embedded in FFmpeg. No Windows GPU
runtime validation is performed by the Linux build script.

## Playback

Run `ffplay input.mp4` (or `.\ffplay.exe input.mp4` on Windows) in a desktop
session. `ffplay -version` verifies the executable without opening a window.
