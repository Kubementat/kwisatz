# OmniVoice.cpp REST API Server

Built-in OpenAI-compatible TTS HTTP server for OmniVoice.cpp.

## Setup from Scratch

Complete guide to deploy the OmniVoice TTS API on a new machine.

### Prerequisites

**Hardware:**
- AMD or NVIDIA GPU with Vulkan support (AMD: Radeon RX 6000+ series recommended)
- Minimum 4 GB VRAM (8 GB recommended)
- Modern CPU with AVX2 support
- 16 GB RAM recommended

**Software (Ubuntu/Debian example):**
```bash
# Build tools
sudo apt update
sudo apt install -y build-essential cmake git

# Vulkan drivers (AMD)
sudo apt install -y mesa-vulkan-drivers vulkan-tools

# Verify Vulkan
vulkaninfo | grep deviceName
```

### Step 1: Clone the Repository

```bash
git clone --recurse-submodules https://github.com/ServeurpersoCom/omnivoice.cpp.git
cd omnivoice.cpp
```

### Step 2: Build for Your GPU

**For AMD/Intel GPUs (Vulkan):**
```bash
./buildvulkan.sh
```

**For NVIDIA GPUs (CUDA):**
```bash
./buildcuda.sh
```

**For CPU-only:**
```bash
./build.sh
```

Build output: `build/omnivoice-tts`, `build/omnivoice-codec`, `build/tts-server`

### Step 3: Download Models

```bash
# Install huggingface-cli
pip install huggingface_hub

# Download models (~1.2 GB total)
mkdir -p models
huggingface-cli download Serveurperso/OmniVoice-GGUF \
  omnivoice-base-Q8_0.gguf omnivoice-tokenizer-F32.gguf \
  --local-dir models
```

**Model files:**
- `omnivoice-base-Q8_0.gguf` - Base LLM (626 MB, Q8_0 quantized)
- `omnivoice-tokenizer-F32.gguf` - Audio codec (702 MB, F32)

### Step 4: Start the Server

```bash
./build/tts-server \
  --model models/omnivoice-base-Q8_0.gguf \
  --codec models/omnivoice-tokenizer-F32.gguf \
  --host 0.0.0.0 \
  --port 8080
```

Server loads models into GPU memory and begins listening.

### Step 5: Register a Voice

```bash
# Base64 encode reference audio
WAV_B64=$(base64 -w0 /path/to/reference.wav)

# Register voice
curl -X POST http://localhost:8080/v1/audio/voices \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"myvoice\", \"ref_text\": \"Transcript of reference audio\", \"wav_b64\": \"$WAV_B64\"}"
```

### Step 6: Generate Speech

```bash
curl -X POST http://localhost:8080/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"input": "Hello world", "voice": "myvoice", "language": "English"}' \
  -o output.wav
```

### Running as a Service (systemd)

Create `/etc/systemd/system/omnivoice.service`:

```ini
[Unit]
Description=OmniVoice TTS Server
After=network.target

[Service]
Type=simple
User=tts
WorkingDirectory=/opt/omnivoice
ExecStart=/opt/omnivoice/build/tts-server --model models/omnivoice-base-Q8_0.gguf --codec models/omnivoice-tokenizer-F32.gguf --host 0.0.0.0 --port 8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable omnivoice
sudo systemctl start omnivoice
```

### Docker Deployment

```dockerfile
FROM ubuntu:24.04
RUN apt update && apt install -y build-essential cmake git mesa-vulkan-drivers python3-pip
RUN pip install huggingface_hub
WORKDIR /opt
RUN git clone --recurse-submodules https://github.com/ServeurpersoCom/omnivoice.cpp.git
WORKDIR /opt/omnivoice
RUN ./buildvulkan.sh
RUN mkdir -p models && huggingface-cli download Serveurperso/OmniVoice-GGUF omnivoice-base-Q8_0.gguf omnivoice-tokenizer-F32.gguf --local-dir models
EXPOSE 8080
CMD ["./build/tts-server", "--model", "models/omnivoice-base-Q8_0.gguf", "--codec", "models/omnivoice-tokenizer-F32.gguf", "--host", "0.0.0.0", "--port", "8080"]
```

Build and run with GPU passthrough:
```bash
docker build -t omnivoice .
docker run --rm -p 8080:8080 --device=/dev/dri omnivoice
```

## Starting the Server

```bash
cd omnivoice.cpp
./build/tts-server --model models/omnivoice-base-Q8_0.gguf --codec models/omnivoice-tokenizer-F32.gguf
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--model <gguf>` | (required) | LLM GGUF model path |
| `--codec <gguf>` | (required) | Codec GGUF model path |
| `--host <ip>` | `127.0.0.1` | Listen address |
| `--port <n>` | `8080` | Listen port |
| `--lang <str>` | `None` | Default language for requests |
| `--no-fa` | | Disable flash attention |
| `--clamp-fp16` | | Clamp hidden states to FP16 range |

### Example: Start on all interfaces

```bash
./build/tts-server --model models/omnivoice-base-Q8_0.gguf --codec models/omnivoice-tokenizer-F32.gguf --host 0.0.0.0 --port 8080
```

## Endpoints

### POST /v1/audio/speech

Text-to-speech synthesis. OpenAI-compatible.

**Request body:**
```json
{
  "input": "Text to speak",
  "voice": "registered_voice_name",
  "language": "English",
  "instructions": "Style guidance",
  "response_format": "wav",
  "seed": -1
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `input` | string | Yes | Text to synthesize |
| `voice` | string | No | Registered voice name (omit for voice design) |
| `language` | string | No | Language label (e.g., "English", "German") |
| `instructions` | string | No | Style instruction for voice design |
| `response_format` | string | No | `"wav"` (one-shot file) or `"pcm"` (streamed). Default: `"pcm"` |
| `seed` | integer | No | Sampling seed. Negative or absent = random. Positive = reproducible. |

**Response:**
- `wav`: Returns a WAV file (audio/wav)
- `pcm`: Streams 16-bit signed little-endian 24kHz mono PCM (audio/pcm)

**Example - WAV output:**
```bash
curl -X POST http://localhost:8080/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"input": "Hello world", "voice": "julian", "language": "English", "response_format": "wav"}' \
  -o output.wav
```

**Example - PCM streaming to speaker:**
```bash
curl -X POST http://localhost:8080/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"input": "Hello world", "voice": "julian", "response_format": "pcm"}' \
  | aplay -r 24000 -f S16_LE -t raw -c 1
```

### POST /v1/audio/voices

Register a cloned voice from reference audio.

**Request body (WAV upload):**
```json
{
  "name": "julian",
  "ref_text": "Transcript of the reference audio",
  "wav_b64": "base64-encoded WAV file"
}
```

**Request body (pre-encoded RVQ):**
```json
{
  "name": "julian",
  "ref_text": "Transcript of the reference audio",
  "rvq_b64": "base64-encoded .rvq file"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Voice identifier |
| `ref_text` | string | Yes | Transcript of the reference audio |
| `wav_b64` | string | One of | Base64-encoded WAV file |
| `rvq_b64` | string | One of | Base64-encoded pre-encoded .rvq codes |

**Example - Register from WAV:**
```bash
WAV_B64=$(base64 -w0 /path/to/reference.wav)
curl -X POST http://localhost:8080/v1/audio/voices \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"julian\", \"ref_text\": \"Hi, my name is Julian\", \"wav_b64\": \"$WAV_B64\"}"
```

**Example - Register from RVQ:**
```bash
RVQ_B64=$(base64 -w0 /path/to/reference.rvq)
curl -X POST http://localhost:8080/v1/audio/voices \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"julian\", \"ref_text\": \"Hi, my name is Julian\", \"rvq_b64\": \"$RVQ_B64\"}"
```

### GET /v1/audio/voices

List all registered voices.

**Response:**
```json
{
  "voices": [
    {"name": "julian"},
    {"name": "alice"}
  ]
}
```

### DELETE /v1/audio/voices/{name}

Remove a registered voice.

**Example:**
```bash
curl -X DELETE http://localhost:8080/v1/audio/voices/julian
```

### GET /v1/models

List loaded models.

**Response:**
```json
{
  "object": "list",
  "data": [
    {
      "id": "omnivoice-base-Q8_0.gguf",
      "object": "model",
      "owned_by": "local"
    }
  ]
}
```

### GET /health

Liveness probe.

**Response:**
```json
{"status": "ok"}
```

## Voice Design (No Reference Audio)

If no `voice` is specified, OmniVoice uses voice design based on `instructions`:

```bash
curl -X POST http://localhost:8080/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{
    "input": "Hello world",
    "instructions": "young female, high pitch, cheerful, fast pace",
    "language": "English",
    "response_format": "wav"
  }' \
  -o output.wav
```

## Pre-encoding Reference Audio

For faster repeated use of the same voice, pre-encode the reference:

```bash
# Encode once
./build/omnivoice-codec --model models/omnivoice-tokenizer-F32.gguf -i reference.wav
# Produces reference.rvq

# Use the .rvq file for registration (faster than WAV)
```

## Error Format

All errors use the OpenAI error envelope:

```json
{
  "error": {
    "message": "Error description",
    "type": "invalid_request_error"
  }
}
```

## CORS

The server enables permissive CORS for browser clients:
- `Access-Control-Allow-Origin: *`
- Methods: GET, POST, DELETE, OPTIONS
- Headers: Content-Type

## Concurrency

Synthesis is serialized FIFO across connections using a single GPU context.
