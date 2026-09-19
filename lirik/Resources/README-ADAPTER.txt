Place MediaRemoteAdapter.framework here after building on macOS (arm64/universal).

  git clone https://github.com/ungive/mediaremote-adapter.git /tmp/mra
  cd /tmp/mra && mkdir build && cd build && cmake .. && cmake --build .
  cp -R MediaRemoteAdapter.framework <this-Resources-folder>/

If the framework is missing at runtime, Lirik falls back to Homebrew `media-control`.
