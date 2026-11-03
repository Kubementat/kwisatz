# ColQwen2.5 embedding service image.
# NGC_PYTORCH_TAG and COLPALI_VERSION are supplied as build args by
# docker-compose from the generated .env - edit .env and rebuild to change
# them (the defaults come from versions.yml). Model weights are NEVER part of
# this image (mounted at runtime).
ARG NGC_PYTORCH_TAG

FROM nvcr.io/nvidia/pytorch:${NGC_PYTORCH_TAG}

ARG COLPALI_VERSION

WORKDIR /app

COPY requirements.txt /app/requirements.txt
# torchao ships with the NGC image but is unused here; peft>=0.19 raises an
# ImportError on NGC's torchao build (instead of ignoring it), which aborts
# LoRA-adapter injection. Removing it makes peft skip its torchao dispatch.
#
# colpali-engine is installed with --no-deps: its torch pin (e.g. <2.9.0 for
# 0.3.13) would otherwise make pip REPLACE the NGC container's CUDA torch
# (a pre-release like 2.9.0a0 does not satisfy "<2.9.0" under PEP 440) with
# a CPU-only PyPI wheel. Its dependencies are installed explicitly instead -
# keep these ranges in sync with COLPALI_VERSION (see .env); the remaining
# deps (torch, torchvision, numpy, scipy, requests) ship with the NGC image.
# The final python -c fails the BUILD if the CUDA torch was replaced after
# all - a silently CPU-only image would only crash at container start.
RUN pip uninstall -y torchao \
    && pip install --no-cache-dir -r /app/requirements.txt \
    && pip install --no-cache-dir \
        "transformers>=4.53.1,<4.58.0" \
        "peft>=0.14.0,<0.18.0" \
        "accelerate>=0.34.0,<1.9.0" \
    && pip install --no-cache-dir --no-deps "colpali-engine==${COLPALI_VERSION}" \
    && python -c "import torch; assert torch.version.cuda, 'CUDA torch was replaced by a CPU wheel'"

COPY app/ /app/

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
