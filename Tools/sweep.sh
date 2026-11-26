#!/bin/bash
# Looks for anything that stops PugglePhotos. Builds the Debug app, then runs its sweep on the made-up sample library
# (never the real Photos library or catalog):
#
#   Tools/sweep.sh                      the tour, then every command done first, in every start state
#   Tools/sweep.sh tour                 the tour alone: everything there is to do, in every place
#   Tools/sweep.sh first [STATE ...]    each command done first thing after a fresh launch, in the start states named
#                                       (library, loading, ask, denied, list, book; all of them if none are)
#
# A run that crashes, hangs or quits early is listed with the last thing it did. Logs of those runs, and of the tour,
# are kept in build/sweep. Exits 1 if any run didn't finish. Every command done first takes a launch of its own, so
# all of it takes about half an hour, with the app's window coming and going all the while.

cd "$(dirname "$0")/.." || exit 2
OUT=build/sweep
APP=build/DerivedData/Build/Products/Debug/PugglePhotos.app/Contents/MacOS/PugglePhotos
ALL_STATES="library loading ask denied list book"

# The launch arguments that start PugglePhotos in each state.
flags_for() {
  case "$1" in
    library) ;;                              # the library, loaded
    loading) echo "-PHSampleLoadDelay 4" ;;  # the library still loading
    ask) echo "-PHAccess ask" ;;             # the welcome screen, before access to Photos is asked for
    denied) echo "-PHAccess denied" ;;       # the welcome screen, access to Photos refused
    list) echo "-PHSavedViewMode list" ;;    # last left showing the list
    book) echo "-PHSavedViewMode book" ;;    # last left showing an album as a book
    *) return 1 ;;
  esac
}

mode=${1:-all}
[ $# -gt 0 ] && shift
case "$mode" in
  all) states=$ALL_STATES ;;
  tour) states= ;;
  first) states=${*:-$ALL_STATES} ;;
  *) echo "Usage: Tools/sweep.sh [tour | first [STATE ...]]" >&2; exit 2 ;;
esac
for state in $states; do
  flags_for "$state" > /dev/null || { echo "There's no start state called $state (try: $ALL_STATES)" >&2; exit 2; }
done

echo "Building the Debug app…"
xcodebuild -project PugglePhotos.xcodeproj -scheme PugglePhotos -configuration Debug -derivedDataPath build/DerivedData \
  -quiet build || exit 1
rm -rf "$OUT"
mkdir -p "$OUT"
failures=0

# run LOG SECONDS ARGUMENTS...: runs the app's sweep, stopped after SECONDS, and says whether it finished.
run() {
  local log=$1 limit=$2 pid code i=0
  shift 2
  # -PHSelfTest keeps it on the sample library, with a catalog of its own.
  "$APP" -PHSelfTest YES -ApplePersistenceIgnoreState YES "$@" > "$log" 2>&1 &
  pid=$!
  while kill -0 $pid 2> /dev/null && [ $i -lt $((limit * 10)) ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 $pid 2> /dev/null; then
    kill $pid
    echo "STOPPED after $limit s" >> "$log"
  fi
  wait $pid
  code=$?
  echo "EXIT $code" >> "$log"
  [ $code -eq 0 ] && grep -q "^SWEEP DONE" "$log"
}

# failed WHAT LOG: lists a run that didn't finish.
failed() {
  local last
  failures=$((failures + 1))
  last=$(grep "^SWEEP DO:" "$2" | tail -1)
  echo "FAILED: $1. The last thing done: ${last#SWEEP DO: }. $(grep -E "Fatal error|Terminating app|^STOPPED|^EXIT" "$2" | head -2 | tr '\n' ' ')($2)"
}

if [ "$mode" != first ]; then
  echo "The tour…"
  run "$OUT/tour.log" 1800 -PHSweep tour || failed "the tour" "$OUT/tour.log"
  grep "^SWEEP DONE" "$OUT/tour.log"
fi

for state in $states; do
  flags=$(flags_for "$state")
  list="$OUT/$state-commands.log"
  # Word splitting of $flags is wanted: it's one argument or a pair.
  run "$list" 60 $flags -PHSweep list
  if ! grep -q "^SWEEP COUNT" "$list"; then
    failed "listing the commands in the start state $state" "$list"
    continue
  fi
  numbers=$(sed -n -E 's/^SWEEP COMMAND ([0-9]+) on: .*/\1/p' "$list")
  echo "Start state $state: $(echo "$numbers" | grep -c .) commands to do first…"
  for n in $numbers; do
    log="$OUT/$state-$n.log"
    if run "$log" 60 $flags -PHSweep "first:$n"; then
      rm "$log"
    else
      failed "$(sed -n -E "s/^SWEEP COMMAND $n on: //p" "$list") first, in the start state $state" "$log"
    fi
  done
done

if [ $failures -gt 0 ]; then
  echo "$failures runs didn't finish."
  exit 1
fi
echo "Every run finished."
