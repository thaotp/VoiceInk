#!/bin/bash

# Launch Ollama with parallel processing enabled
# This allows handling multiple translation requests concurrently
# increasing responsiveness in Lyric Mode "Live Translation".

echo "Starting Ollama with OLLAMA_NUM_PARALLEL=2..."
export OLLAMA_NUM_PARALLEL=2
ollama serve
