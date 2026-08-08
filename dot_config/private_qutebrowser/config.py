# Avalon Amber - qutebrowser chrome, plus a gentle amber tint on web content

config.load_autoconfig()

c.fonts.default_family = "3270 Nerd Font Propo"
c.fonts.default_size = "14pt"
c.fonts.prompts = "14pt 3270 Nerd Font Propo"

c.tabs.show = "multiple"
c.statusbar.show = "in-mode"
c.tabs.last_close = "close"

# Statusbar
c.colors.statusbar.normal.bg = "#17110a"
c.colors.statusbar.normal.fg = "#c9973a"
c.colors.statusbar.insert.bg = "#4a3823"
c.colors.statusbar.insert.fg = "#f4e4c1"
c.colors.statusbar.command.bg = "#17110a"
c.colors.statusbar.command.fg = "#c9973a"
c.colors.statusbar.url.fg = "#c9973a"
c.colors.statusbar.url.success.http.fg = "#8a6d3f"
c.colors.statusbar.url.success.https.fg = "#e8b969"
c.colors.statusbar.url.hover.fg = "#f4e4c1"
c.colors.statusbar.url.warn.fg = "#e8b969"
c.colors.statusbar.url.error.fg = "#7a4a1e"

# Tabs
c.colors.tabs.bar.bg = "#0d0906"
c.colors.tabs.odd.bg = "#17110a"
c.colors.tabs.odd.fg = "#8a6d3f"
c.colors.tabs.even.bg = "#17110a"
c.colors.tabs.even.fg = "#8a6d3f"
c.colors.tabs.selected.odd.bg = "#4a3823"
c.colors.tabs.selected.odd.fg = "#f4e4c1"
c.colors.tabs.selected.even.bg = "#4a3823"
c.colors.tabs.selected.even.fg = "#f4e4c1"
c.colors.tabs.indicator.start = "#c9973a"
c.colors.tabs.indicator.stop = "#e8b969"

# Completion menu
c.colors.completion.fg = "#c9973a"
c.colors.completion.odd.bg = "#0d0906"
c.colors.completion.even.bg = "#17110a"
c.colors.completion.category.fg = "#f4e4c1"
c.colors.completion.category.bg = "#221a10"
c.colors.completion.item.selected.bg = "#4a3823"
c.colors.completion.item.selected.fg = "#f4e4c1"
c.colors.completion.item.selected.border.top = "#c9973a"
c.colors.completion.item.selected.border.bottom = "#c9973a"
c.colors.completion.match.fg = "#e8b969"
c.colors.completion.scrollbar.bg = "#0d0906"
c.colors.completion.scrollbar.fg = "#4a3823"

# Downloads
c.colors.downloads.bar.bg = "#17110a"
c.colors.downloads.start.bg = "#4a3823"
c.colors.downloads.start.fg = "#f4e4c1"
c.colors.downloads.stop.bg = "#c9973a"
c.colors.downloads.stop.fg = "#0d0906"

# Hints & messages
c.colors.hints.bg = "#c9973a"
c.colors.hints.fg = "#0d0906"
c.colors.hints.match.fg = "#f4e4c1"
c.colors.messages.info.bg = "#17110a"
c.colors.messages.info.fg = "#c9973a"
c.colors.messages.warning.bg = "#4a3823"
c.colors.messages.warning.fg = "#f4e4c1"
c.colors.messages.error.bg = "#7a4a1e"
c.colors.messages.error.fg = "#f4e4c1"

# Web content: prefer sites' own dark theme, force Chromium dark mode as a
# fallback for sites that don't offer one, and lay a gentle warm tint over
# everything (deliberately not a full color invert - that breaks photos,
# videos, and logos on most real sites).
c.colors.webpage.bg = "#0d0906"
c.colors.webpage.preferred_color_scheme = "dark"
c.colors.webpage.darkmode.enabled = True
c.content.user_stylesheets = ["/home/mguillen/.config/qutebrowser/amber-tint.css"]
