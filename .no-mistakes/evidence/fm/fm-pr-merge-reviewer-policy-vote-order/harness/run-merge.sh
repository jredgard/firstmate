#!/usr/bin/env bash
# Run the real bin/fm-pr-merge.sh from the gate worktree against the lab home,
# routing curl/gh/gh-axi through the disposable forge emulator.
LAB=/tmp/fm-lab.V0GmFX
WT=/home/johannesr/.no-mistakes/worktrees/551ff26a6b1c/01M443Y636779T2GZQNWYHNYJJ
exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN \
  -u http_proxy -u HTTP_PROXY -u no_proxy -u NO_PROXY \
  FM_HOME="$LAB/home" HOME="$LAB/user-home" \
  https_proxy="http://127.0.0.1:${EMU_PORT:-18443}" HTTPS_PROXY="http://127.0.0.1:${EMU_PORT:-18443}" \
  SSL_CERT_FILE="$LAB/pki/ca.pem" CURL_CA_BUNDLE="$LAB/pki/ca.pem" NODE_EXTRA_CA_CERTS="$LAB/pki/ca.pem" \
  GH_CONFIG_DIR="$LAB/gh-config" GH_TOKEN=lab-merger-token GH_NO_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 GH_NO_EXTENSION_UPDATE_NOTIFIER=1 \
  PATH="$LAB/fakebin:$PATH" \
  "$WT/bin/fm-pr-merge.sh" "$@"
