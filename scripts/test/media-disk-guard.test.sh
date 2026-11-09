#!/usr/bin/env bash
# Tests de scripts/lib/media-disk-guard.sh
#
# Uso: bash scripts/test/media-disk-guard.test.sh
#
# Son read-only: ejercitan las verificaciones del guard, nunca formatean nada.
# Corren sin root; los chequeos que necesitan privilegios simplemente no
# resuelven y el guard los trata como "no concluyente" (nunca como "seguro").
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/media-disk-guard.sh
source "$HERE/../lib/media-disk-guard.sh"

pass=0
fail=0
skip=0

ok()   { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
skipped() { printf 'skip %s\n' "$1"; skip=$((skip + 1)); }

# expect <desc> <0-espera-exito|1-espera-fallo> <comando...>
expect() {
  local desc="$1" want="$2"
  shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  if [[ "$want" == 0 && $rc -eq 0 ]] || [[ "$want" == 1 && $rc -ne 0 ]]; then
    ok "$desc"
  else
    bad "$desc (rc=$rc, esperaba $want)"
  fi
}

# ── identificadores del disco del sistema ─────────────────────────────────────
# El by-path NO se hardcodea: cambia con la motherboard y con el puerto SATA.
# Si se hardcodea, tras cambiar hardware la segunda defensa del guard queda
# muerta y el script solo se salva por el backstop de tamaño.

if [[ -z "${SYS_BY_PATH:-}" ]]; then
  bad "SYS_BY_PATH se deriva del by-id (quedó vacío)"
else
  ok "SYS_BY_PATH se deriva del by-id ($SYS_BY_PATH)"
  expect "el by-path derivado existe" 0 test -e "/dev/disk/by-path/$SYS_BY_PATH"

  sys_by_id="$(readlink -f "/dev/disk/by-id/$SYS_BY_ID" 2>/dev/null || true)"
  sys_by_path="$(readlink -f "/dev/disk/by-path/$SYS_BY_PATH" 2>/dev/null || true)"
  if [[ -n "$sys_by_id" && "$sys_by_id" == "$sys_by_path" ]]; then
    ok "by-id y by-path apuntan al mismo dispositivo ($sys_by_id)"
  else
    bad "by-id ($sys_by_id) y by-path ($sys_by_path) no coinciden"
  fi
fi

# ── resolución del disco del sistema ──────────────────────────────────────────
sys_dev="$(resolve_system_dev 2>/dev/null || true)"
if [[ -n "$sys_dev" && -b "$sys_dev" ]]; then
  ok "resolve_system_dev resuelve a un bloque real ($sys_dev)"
else
  bad "resolve_system_dev no resolvió a un dispositivo de bloque"
fi

# ── el guard rechaza lo que no debe tocar ─────────────────────────────────────
expect "rechaza el disco del sistema" 1 assert_safe_to_wipe "${sys_dev:-/dev/null}"
expect "rechaza un dispositivo que no es de bloque" 1 assert_safe_to_wipe /dev/null
expect "rechaza un path inexistente" 1 assert_safe_to_wipe /dev/does-not-exist

# Una rama montada del pool: se toma dinámicamente, sin /dev/sdX hardcodeado.
branch_src="$(findmnt -rn -o SOURCE /mnt/media1 2>/dev/null | head -1 || true)"
branch_dev=""
if [[ -n "$branch_src" ]]; then
  branch_dev="/dev/$(lsblk -no PKNAME "$branch_src" 2>/dev/null | head -1 | tr -d ' ')"
fi
if [[ -n "$branch_dev" && -b "$branch_dev" ]]; then
  expect "rechaza un disco montado ($branch_dev)" 1 assert_safe_to_wipe "$branch_dev"
else
  skipped "rechaza un disco montado (no hay rama montada)"
fi

# ── falla cerrado ─────────────────────────────────────────────────────────────
# Si no se puede identificar el disco del sistema, el guard NO puede dar por
# buena la operación: tiene que abortar en vez de saltear el chequeo.
_fail_closed_require() {
  (
    resolve_system_dev() { return 1; }
    require_system_dev
  )
}
# Captura stderr para verificar en QUÉ chequeo aborta: rc=1 solo no alcanza
# (un disco montado también da rc=1, y el test pasaría por el motivo equivocado).
_fail_closed_assert_stderr() {
  (
    resolve_system_dev() { return 1; }
    assert_safe_to_wipe "$1"
  ) 2>&1
}
expect "require_system_dev falla si no hay disco de sistema" 1 _fail_closed_require

if [[ -n "${branch_dev:-}" && -b "${branch_dev:-}" ]]; then
  fc_out="$(_fail_closed_assert_stderr "$branch_dev" || true)"
  if [[ "$fc_out" == *"no puedo identificar el disco del sistema"* ]]; then
    ok "assert_safe_to_wipe aborta en el chequeo del disco de sistema"
  else
    bad "assert_safe_to_wipe no abortó donde debía (salida: ${fc_out:0:90})"
  fi
else
  skipped "assert_safe_to_wipe aborta en el chequeo del disco de sistema (sin rama montada)"
fi

printf '\n%d ok, %d fail, %d skip\n' "$pass" "$fail" "$skip"
[[ $fail -eq 0 ]]
