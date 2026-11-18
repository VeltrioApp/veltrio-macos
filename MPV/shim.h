// Umbrella for libmpv's headers so Swift can `import mpv`.
// The real headers are resolved via HEADER_SEARCH_PATHS pointing at
// /opt/homebrew/include (Homebrew's libmpv install).

#pragma once

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>
#include <mpv/stream_cb.h>
