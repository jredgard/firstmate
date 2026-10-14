. /tmp/fm-live-drv/common.sh
setup() {
  mkdir -p "$WTD/config"
  cat > "$WTD/RULING.md" <<'R'
# Accepted ruling for task demo (settings header flag)
Required evidence: (1) unit tests green; (2) config/appsettings.json sets FeatureFlags.NewHeader to true.
A browser check of the settings page is NOT required evidence for this task.
R
  printf '{ "FeatureFlags": { "NewHeader": true } }\n' > "$WTD/config/appsettings.json"
  gitrepo
}
trigger() { status_blocked "unit tests green; I cannot perform the browser check of the settings page (no browser in this sandbox). Ruling is $WTD/RULING.md. Should I skip the browser probe?"; }
