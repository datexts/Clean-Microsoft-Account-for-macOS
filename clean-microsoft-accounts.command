#!/bin/zsh
# Clears every Microsoft sign-in remembered on this Mac (Teams, Office, OneDrive),
# including the copies in the local-items keychain that survive app reinstalls.
# Double-click to run, or pass --dry-run to only show what would be removed.
#
# WARNING: this edits the macOS keychain database directly, which Apple does not
# support. A backup is taken first, but use it at your own risk.

setopt null_glob

# Keychain access group where Microsoft apps keep accounts and tokens.
GROUP='UBF8T346G9.com.microsoft.identity.universalstorage'
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Apps that may hold unsaved documents: the user quits these.
ASK_QUIT=(
  'Outlook:/Microsoft Outlook.app/Contents/MacOS/'
  'Word:/Microsoft Word.app/Contents/MacOS/'
  'Excel:/Microsoft Excel.app/Contents/MacOS/'
  'PowerPoint:/Microsoft PowerPoint.app/Contents/MacOS/'
  'OneNote:/Microsoft OneNote.app/Contents/MacOS/'
)
# Apps with nothing to save: closed automatically.
AUTO_QUIT=(
  '/Microsoft Teams.app/Contents/MacOS/MSTeams'
  '/OneDrive.app/Contents/'
)

DRY_RUN=0
[[ "$1" == "--dry-run" ]] && DRY_RUN=1

finish() {
  [[ -t 0 ]] && read "?Press Enter to close this window "
  exit "$1"
}

group_count() {
  local n
  n=$(sqlite3 -readonly "$1" "SELECT count(*) FROM genp WHERE agrp='$GROUP';" 2>/dev/null)
  echo "${n:-0}"
}

login_dump() {
  security dump-keychain "$LOGIN_KEYCHAIN" 2>/dev/null
}

# Email addresses of the accounts Teams/Office currently remember.
remembered_accounts() {
  login_dump | awk '
    /"gena"<blob>=0x/ { g = $0 }
    /"svce"<blob>="OneAuthAccount"/ {
      if (match(g, /login_name\\?": \\?"[^"\\]+/)) print substr(g, RSTART, RLENGTH)
    }
    /^keychain:/ { g = "" }' | sed -E 's/^login_name[": \\]*//'
}

oneauth_count() {
  login_dump | grep -c '"svce"<blob>="OneAuthAccount"'
}

office_identity_items() {
  login_dump | grep -oE '"acct"<blob>="Microsoft Office Identities [^"]+"' \
    | sed -E 's/^"acct"<blob>="//; s/"$//'
}

running_ask_apps() {
  local entry
  for entry in $ASK_QUIT; do
    pgrep -f "${entry#*:}" >/dev/null && echo "${entry%%:*}"
  done
}

echo "=== Clean Microsoft sign-in records ==="
echo

# --- 1. Show what is there -------------------------------------------------
DBS=()
TOTAL_GROUP=0
for db in "$HOME"/Library/Keychains/*/keychain-2.db; do
  n=$(group_count "$db")
  if (( n > 0 )); then
    DBS+=("$db")
    (( TOTAL_GROUP += n ))
  fi
done
ONEAUTH=$(oneauth_count)
OFFICE_ITEMS=("${(@f)$(office_identity_items)}")
OFFICE_ITEMS=(${OFFICE_ITEMS:#})

echo "Accounts currently remembered:"
ACCOUNTS=$(remembered_accounts)
if [[ -n "$ACCOUNTS" ]]; then
  echo "$ACCOUNTS" | sed 's/^/  - /'
else
  echo "  (none in the login keychain)"
fi
echo
echo "Will delete:"
echo "  Local-items keychain, Microsoft sign-in records: $TOTAL_GROUP"
echo "  Login keychain, account copies: $ONEAUTH"
echo "  Login keychain, Office identity records: ${#OFFICE_ITEMS}"
echo

if (( TOTAL_GROUP == 0 && ONEAUTH == 0 && ${#OFFICE_ITEMS} == 0 )); then
  echo "Nothing to clean."
  finish 0
fi

if (( DRY_RUN )); then
  echo "(--dry-run: nothing was changed)"
  exit 0
fi

echo "Note: all accounts are removed together; a single account cannot be picked."
echo "Teams, OneDrive, Outlook, Word, Excel and OneNote will need to sign in again."
echo
read "ans?Type yes to continue, anything else to cancel: "
if [[ "$ans" != "yes" ]]; then
  echo "Cancelled. Nothing was changed."
  finish 0
fi

# --- 2. Make sure no Microsoft app can write the accounts back --------------
while true; do
  running=("${(@f)$(running_ask_apps)}")
  running=(${running:#})
  (( ${#running} == 0 )) && break
  echo
  echo "Still running, save your work and quit (Cmd+Q): ${(j:, :)running}"
  read "ans?Press Enter when done (or type q to cancel): "
  if [[ "$ans" == "q" ]]; then
    echo "Cancelled. Nothing was changed."
    finish 0
  fi
done
for pattern in $AUTO_QUIT; do
  pkill -f "$pattern" 2>/dev/null
done
sleep 2

# --- 3. Back up, then delete from the local-items keychain ------------------
BACKUP="$HOME/keychain-backup-$(date +%Y%m%d-%H%M%S)"
for db in $DBS; do
  dir=${db:h}
  mkdir -p "$BACKUP" && chmod 700 "$BACKUP"
  if ! cp -R "$dir" "$BACKUP/"; then
    echo "Backup failed, stopping. Nothing was deleted: $dir"
    finish 1
  fi
done
(( ${#DBS} > 0 )) && echo "Backed up to: ${BACKUP/#$HOME/~}"

for db in $DBS; do
  deleted=$(sqlite3 -cmd ".timeout 5000" "$db" \
    "DELETE FROM genp WHERE agrp='$GROUP'; SELECT changes();" 2>&1)
  if [[ "$deleted" != <-> ]]; then
    echo "Delete failed, stopping: $deleted"
    finish 1
  fi
  check=$(sqlite3 -readonly "$db" "PRAGMA quick_check;" 2>&1 | head -1)
  echo "Local-items keychain: deleted $deleted (database check: $check)"
  if [[ "$check" != "ok" ]]; then
    echo "Database check failed, stopping. Restart the Mac; if problems remain, restore the backup above."
    finish 1
  fi
done

# --- 4. Delete the copies in the login keychain ----------------------------
n=0
while security delete-generic-password -s OneAuthAccount "$LOGIN_KEYCHAIN" >/dev/null 2>&1; do
  (( ++n >= 200 )) && break
done
echo "Login keychain, account copies: deleted $n"

n=0
for acct in $OFFICE_ITEMS; do
  security delete-generic-password -a "$acct" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 && (( n++ ))
done
echo "Login keychain, Office identity records: deleted $n"

# --- 5. Verify -------------------------------------------------------------
LEFT=0
for db in "$HOME"/Library/Keychains/*/keychain-2.db; do
  (( LEFT += $(group_count "$db") ))
done
(( LEFT += $(oneauth_count) ))
echo
if (( LEFT == 0 )); then
  echo "Done. Open Teams: the account picker should now be empty."
else
  echo "$LEFT item(s) could not be removed; a Microsoft app may still be running in the background. Restart the Mac and run this again."
fi
(( ${#DBS} > 0 )) && echo "Once everything works, you can delete the backup: ${BACKUP/#$HOME/~}"
finish 0
