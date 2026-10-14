status_blocked() { printf 'blocked [key=routine-stop] [at=%s]: %s\n' "$(date +%s)" "$1" >> "$ST/demo.status"; }
gitrepo() {
  git -C "$WTD" init -q -b fm/demo && git -C "$WTD" -c user.name=w -c user.email=w@x commit -q --allow-empty -m "task: base" 
}
