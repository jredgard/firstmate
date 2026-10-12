#!/usr/bin/env bash
# Cross-variant consistency check over emitted briefs (generated public output).
fails=0
for f in brief-live-*.md; do
  v=${f#brief-live-}; v=${v%.md}
  r7=$(grep -c '^7\. Never administer infrastructure that every lane shares' "$f")
  refs=$(grep -c 'rule 7' "$f")
  bad=$(grep -cE 'reattach at once|without flags|Only after ruling out socket refusal|run the same blocking command again' "$f")
  startgate=$(grep -c 'only when no active run owns your current branch' "$f")
  respondnever=$(grep -c 'Never send the same `respond` again' "$f")
  reat=$(grep -o 'when reattaching, use `no-mistakes axi run` [^,]*\(and a bounded `--wait`\|bounded `--wait`\)' "$f" | sort -u | tr '\n' '|')
  skipline=$(grep -o 'Pass `--skip [^`]*` on every' "$f" | sort -u)
  status=ok
  [ "$r7" = 1 ] || status="FAIL(no rule7)"
  [ "$bad" = 0 ] || status="FAIL(contradictory legacy wording x$bad)"
  [ "$startgate" = 1 ] || status="FAIL(no ownership rule)"
  printf '%-28s rule7=%s rule7-refs=%s legacy-hits=%s respond-never=%s reattach=[%s] skip=[%s] -> %s\n' "$v" "$r7" "$refs" "$bad" "$respondnever" "$reat" "$skipline" "$status"
  [ "$status" = ok ] || fails=$((fails+1))
done
echo "failures=$fails"
