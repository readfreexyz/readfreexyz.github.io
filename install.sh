#!/bin/sh
# Read Free: install it, and keep it up to date. macOS and Linux.
#
#   curl -fsSLO <the site>/install.sh && sh install.sh
#
#   sh install.sh             download the latest release, check its signature, unpack it into
#                             the Read Free folder, and check for updates every hour
#   sh install.sh update      check for an update now (what the hourly job runs)
#   sh install.sh status      the folder, the version, the last log lines
#   sh install.sh uninstall   stop checking for updates (the folder stays until you delete it)
#   install --no-schedule     install without the hourly job
#
# Then, once, in Chrome (or Edge, Brave, Vivaldi, Dia): chrome://extensions, Developer mode on, Load
# unpacked, and the folder this prints. Leave Developer mode on: with it off, Chrome turns
# unpacked extensions off when they reload, and Read Free reloads itself after each update.
#
# Every release is signed. This script holds the project's public key (SIGNER) and installs only
# a release signed with it, newer than the one installed, whose zip has the signed SHA-256. The
# hourly job runs the copy of this script kept next to the extension, never a fresh download, so
# a site or mirror in the wrong hands can't put code in your browser. Running a newer install.sh
# by hand replaces that copy.
# Where things go: on macOS ~/Library/Application Support/Read Free (log in ~/Library/Logs/Read
# Free, job: a LaunchAgent), on Linux ~/.local/share/read-free (job: a crontab line). The copy is
# "Read Free updater" on macOS, which names the job in System Settings' Login Items (it lists a
# LaunchAgent by its program's file name), and update.sh on Linux.
set -eu
umask 022

# Where releases are published, tried in order: the site, then mirrors. https, ending in /,
# separated by spaces. The same list as RELEASE_URLS in extension/src/settings.js.
RELEASE_URLS='https://readfree.xyz/ https://readfreexyz.github.io/'
# The release key's public half, as an allowed_signers line (tools/release.sh keygen writes it).
SIGNER='read-free namespaces="read-free-release" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINYpjAv6OljQ8lBV7Chb0mZHXwxxMKSBS/0FbxiJLCPn'
NAMESPACE=read-free-release
PRINCIPAL=read-free
MAX_ZIP=52428800

die() { echo "read-free: $*" >&2; exit 1; }
say() { echo "read-free: $*"; }
stamp() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
# Said only to a person at a terminal; the hourly job logs updates and failures alone
chat() { if [ -t 1 ]; then say "$*"; fi; }
# What went wrong with an address: said at once to a person, logged by the hourly job only if
# the run ends in an update or a failure (a mirror that's down isn't news every hour)
TRAIL=''
NL='
'
note() { if [ -t 1 ]; then stamp "$*"; else TRAIL="$TRAIL$(stamp "$*")$NL"; fi; }
trail() { printf '%s' "$TRAIL"; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 isn't installed${2:+ ($2)}"; }

[ "$(id -u)" -ne 0 ] || die "run it as yourself, not as root"
case "$(uname -s)" in
  Darwin)
    BASE="$HOME/Library/Application Support/Read Free"
    LOGDIR="$HOME/Library/Logs/Read Free"
    LABEL=local.readfree.update
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    SELF="$BASE/Read Free updater"
    ;;
  Linux)
    BASE="${XDG_DATA_HOME:-$HOME/.local/share}/read-free"
    LOGDIR=$BASE
    SELF="$BASE/update.sh"
    ;;
  *) die "this script is for macOS and Linux" ;;
esac
EXT="$BASE/extension"
LOG="$LOGDIR/update.log"
LOCK="$BASE/.update.lock"
CRON_MARK='# read-free-update'

configured() {
  [ -n "$RELEASE_URLS" ] || die "this copy has no release address (RELEASE_URLS)"
  for url in $RELEASE_URLS; do
    case "$url" in https://*/) ;; *) die "not an https address ending in /: $url" ;; esac
  done
  case "$SIGNER" in "$PRINCIPAL namespaces=\"$NAMESPACE\" ssh-ed25519 "*) ;; *) die "this copy has no signing key (SIGNER)" ;; esac
  need curl
  need unzip
  need ssh-keygen "OpenSSH"
  if ssh-keygen -Y 2>&1 | grep -Eqi 'illegal option|invalid option|unknown option'; then die "ssh-keygen is too old to check signatures (OpenSSH 8.1 or later)"; fi
  command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 || die "neither shasum nor sha256sum is installed"
}

sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
size_of() { wc -c < "$1" | tr -d ' '; }
is_version() { printf '%s' "$1" | grep -Eqx '[0-9]{1,5}(\.[0-9]{1,5}){0,3}'; }
# $1 newer than $2, numerically: 0.14.10 is newer than 0.14.9
newer() {
  awk -v a="$1" -v b="$2" 'BEGIN { n = split(a, x, "."); m = split(b, y, "."); k = n > m ? n : m
    for (i = 1; i <= k; i++) { p = x[i] + 0; q = y[i] + 0; if (p > q) exit 0; if (p < q) exit 1 }
    exit 1 }'
}
version_in() { sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([0-9.]*\)".*/\1/p' "$1" 2>/dev/null | head -n 1; }
installed() { version_in "$EXT/manifest.json"; }
# https only, redirects included; at most $3 bytes
fetch() { curl -fsSL --proto '=https' --proto-redir '=https' --max-time 300 --max-filesize "$3" -o "$2" "$1" 2>/dev/null; }
field() { sed -n "s/^$1=//p" "$RELEASE/latest.txt" | head -n 1; }

# The signed description of the newest release at $1, checked, into $RELEASE and $version,
# $zip, $sha, $size. Nothing in it is read before its signature checks out.
describe() {
  rm -rf "$RELEASE"
  mkdir "$RELEASE"
  if ! fetch "${1}latest.txt" "$RELEASE/latest.txt" 4096 || ! fetch "${1}latest.txt.sig" "$RELEASE/latest.txt.sig" 4096; then
    note "$1: no answer"
    return 1
  fi
  printf '%s\n' "$SIGNER" > "$RELEASE/allowed_signers"
  if ! ssh-keygen -Y verify -f "$RELEASE/allowed_signers" -I "$PRINCIPAL" -n "$NAMESPACE" -s "$RELEASE/latest.txt.sig" < "$RELEASE/latest.txt" > /dev/null 2>&1; then
    note "$1: latest.txt isn't signed with the Read Free key; ignored"
    return 1
  fi
  version=$(field version)
  zip=$(field zip)
  sha=$(field sha256)
  size=$(field size)
  if [ "$(head -n 1 "$RELEASE/latest.txt")" != "read-free-release 1" ] || ! is_version "$version" || [ "$zip" != "read-free-$version.zip" ] \
    || ! printf '%s' "$sha" | grep -Eqx '[0-9a-f]{64}' || ! printf '%s' "$size" | grep -Eqx '[0-9]{1,9}' || [ "$size" -gt "$MAX_ZIP" ]; then
    note "$1: latest.txt isn't a release this script knows; ignored"
    return 1
  fi
}

# The release described, from $1: downloaded, checked against the signed size and SHA-256, and
# unpacked into $NEW.
unpack() {
  if ! fetch "$1$zip" "$RELEASE/$zip" "$size"; then note "$1$zip: no answer"; return 1; fi
  if [ "$(size_of "$RELEASE/$zip")" != "$size" ] || [ "$(sha256 "$RELEASE/$zip")" != "$sha" ]; then
    note "$1$zip isn't the file that was signed; ignored"
    return 1
  fi
  rm -rf "$NEW"
  mkdir "$NEW"
  if ! unzip -q -o "$RELEASE/$zip" -d "$NEW" > /dev/null 2>&1 || [ "$(version_in "$NEW/manifest.json")" != "$version" ]; then
    note "$1$zip doesn't hold Read Free $version; ignored"
    return 1
  fi
}

lock() {
  if ! mkdir "$LOCK" 2>/dev/null; then
    # One left by a run that was killed: older than an hour
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || return 1; else return 1; fi
  fi
  LOCKED=1
}
cleanup() {
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  [ -n "${LOCKED:-}" ] && rmdir "$LOCK" 2>/dev/null
  return 0
}

# Check the release addresses in turn; the first signed answer says what the newest release is.
# Install it if it's newer than the one here. Returns 1 if nothing answered.
update() {
  configured
  mkdir -p "$BASE" "$LOGDIR"
  lock || { chat "another update is running"; return 0; }
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM
  if [ -f "$LOG" ] && [ "$(size_of "$LOG")" -gt 200000 ]; then tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; fi
  # Unpacked next to the extension, so putting it in place is a rename
  WORK=$(mktemp -d "$BASE/.update.XXXXXX") && [ -d "$WORK" ] || { WORK=''; stamp "couldn't make a working folder in $BASE"; return 1; }
  RELEASE="$WORK/release"
  NEW="$WORK/extension"
  current=$(installed)
  for url in $RELEASE_URLS; do
    describe "$url" || continue
    if ! newer "$version" "${current:-0}"; then
      chat "up to date (${current})"
      return 0
    fi
    unpack "$url" || continue
    if [ -d "$EXT" ]; then
      mv "$EXT" "$WORK/old" || { trail; stamp "couldn't move $EXT aside; kept $current"; return 1; }
      if ! mv "$NEW" "$EXT"; then
        mv "$WORK/old" "$EXT"
        trail
        stamp "couldn't put $version in place; kept $current"
        return 1
      fi
    else
      mv "$NEW" "$EXT"
    fi
    trail
    stamp "updated: ${current:-nothing} -> $version (from $url)"
    return 0
  done
  trail
  stamp "no release address gave a signed release"
  return 1
}

schedule() {
  case "$(uname -s)" in
    Darwin)
      xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
      mkdir -p "$(dirname "$PLIST")"
      cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml "$SELF")</string>
    <string>update</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$(xml "$LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(xml "$LOG")</string>
</dict>
</plist>
EOF
      plutil -lint -s "$PLIST" || die "the LaunchAgent didn't come out right: $PLIST"
      launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$PLIST" || die "launchctl couldn't load $PLIST"
      say "checks for updates at login and every hour (LaunchAgent $LABEL; log: $LOG)"
      # macOS names the job after the program it runs, this copy (sfltool dumpbtm: "Name: Read Free updater")
      say "macOS may say a background item was added: that's this check, which System Settings lists under Login Items as $(basename "$SELF")"
      ;;
    Linux)
      if ! command -v crontab >/dev/null 2>&1; then
        say "no crontab here: run \"sh '$SELF' update\" now and then, or add it to your scheduler"
        return 0
      fi
      case "$SELF$LOG" in *"'"*) die "the folder's path has a ' in it" ;; esac
      line="$(( $(date +%s) % 60 )) * * * * /bin/sh '$SELF' update >> '$LOG' 2>&1 $CRON_MARK"
      { crontab -l 2>/dev/null | grep -vF "$CRON_MARK" || true; echo "$line"; } | crontab - || die "couldn't add the crontab line"
      say "checks for updates every hour (crontab; log: $LOG)"
      ;;
  esac
}

install() {
  configured
  # The hourly job needs this script as a file
  [ -f "$0" ] && grep -q '^SIGNER=' "$0" 2>/dev/null || die "download this script and run it as a file: curl -fsSLO <the site>/install.sh && sh install.sh"
  mkdir -p "$BASE" "$LOGDIR"
  ( update ) || die "couldn't install: see the lines above"
  copied=''
  if [ "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" != "$SELF" ]; then
    cp "$0" "$SELF.tmp"
    chmod 755 "$SELF.tmp"
    mv "$SELF.tmp" "$SELF"
    copied=1
  fi
  # The LaunchAgent runs the copy itself, so it must be executable (it starts with #!/bin/sh)
  chmod 755 "$SELF"
  if [ "${1:-}" != --no-schedule ]; then
    schedule
    # An older script kept its copy as update.sh on macOS too; the LaunchAgent now runs this one
    if [ "$SELF" != "$BASE/update.sh" ]; then rm -f "$BASE/update.sh"; fi
  fi
  version=$(installed)
  echo
  echo "Read Free $version is in:"
  echo "  $EXT"
  echo
  echo "Once, in Chrome (or Edge, Brave, Vivaldi, Dia):"
  echo "  1. Open chrome://extensions and turn on Developer mode (top right). Leave it on:"
  echo "     with it off, Chrome turns Read Free off when it updates itself."
  # On a Mac, with a person at the terminal: Finder opens with the folder selected, to drag onto
  # chrome://extensions (Chrome loads a folder dropped there once Developer mode is on), and its
  # path is copied for Load unpacked, whose dialog doesn't show ~/Library by itself.
  mac=''; [ "$(uname -s)" = Darwin ] && [ -t 1 ] && mac=1
  copiedPath=''; if [ -n "$mac" ] && printf '%s' "$EXT" | pbcopy 2>/dev/null; then copiedPath=1; fi
  if [ -n "$mac" ] && open -R "$EXT" 2>/dev/null; then
    echo "  2. Drag the folder selected in the Finder window that just opened (it's called"
    echo "     \"$(basename "$EXT")\") onto that page."
    if [ -n "$copiedPath" ]; then
      echo "     Or click Load unpacked: its path is copied, so press Cmd+Shift+G, paste, and press Return."
    fi
  else
    echo "  2. Click Load unpacked and choose the folder above."
    if [ -n "$copiedPath" ]; then
      echo "     Its path is copied: in that window press Cmd+Shift+G, paste, and press Return."
    fi
  fi
  echo
  echo "Later, to see how it's doing, or to stop the updates:"
  echo "  sh '$SELF' status"
  echo "  sh '$SELF' uninstall"
  # The copy that was run (curl -O leaves it where the command was pasted) isn't needed again
  if [ -n "$copied" ]; then echo "You can delete $0: Read Free keeps its own copy, called $(basename "$SELF")."; fi
}

status() {
  echo "folder: $EXT"
  echo "  version: $(installed || true)"
  case "$(uname -s)" in
    Darwin)
      if launchctl print "gui/$(id -u)/$LABEL" > /dev/null 2>&1; then echo "updates: LaunchAgent $LABEL, loaded"; else echo "updates: not scheduled"; fi ;;
    Linux)
      if crontab -l 2>/dev/null | grep -qF "$CRON_MARK"; then echo "updates: crontab, hourly"; else echo "updates: not scheduled"; fi ;;
  esac
  echo "log: $LOG"
  if [ -f "$LOG" ]; then tail -n 5 "$LOG" | sed 's/^/  /'; fi
}

uninstall() {
  case "$(uname -s)" in
    Darwin)
      launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
      rm -f "$PLIST" ;;
    Linux)
      if crontab -l 2>/dev/null | grep -qF "$CRON_MARK"; then
        { crontab -l 2>/dev/null | grep -vF "$CRON_MARK" || true; } | crontab -
      fi ;;
  esac
  say "no longer checks for updates. Remove Read Free in chrome://extensions, then delete $BASE"
}

case "${1:-install}" in
  install) install "${2:-}" ;;
  --no-schedule) install --no-schedule ;;
  update) update ;;
  status) status ;;
  uninstall) uninstall ;;
  *) echo "usage: sh $0 [install [--no-schedule] | update | status | uninstall]" >&2; exit 2 ;;
esac
