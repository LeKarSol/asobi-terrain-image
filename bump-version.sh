#!/usr/bin/env bash
set -euo pipefail

# bump-version.sh — bump de la imagen de asobi y lanzamiento del build en CI.
#
#  1. Comprueba que el tag v<VERSION> existe en widgrensit/asobi.
#  2. Sube la versión por defecto en el Dockerfile.
#  3. Commit + push.
#  4. Push del tag asobi-v<VERSION> (dispara el workflow 'Build image').
#
# Uso:
#   ./bump-version.sh [X.Y.Z]   (si no se pasa, usa la última release publicada)

cd "$(dirname "$0")"

UPSTREAM="widgrensit/asobi"
DOCKERFILE="Dockerfile"

die() { echo "error: $*" >&2; exit 1; }

# --- versión actual por defecto en el Dockerfile -------------------------
current_version() {
    grep -E '^ARG[[:space:]]+ASOBI_REF=v[0-9]' "$DOCKERFILE" \
        | sed -E 's/^.*ASOBI_REF=v([0-9](\.[0-9]+)*).*/\1/' \
        | head -1
}

# --- última release publicada de asobi -----------------------------------
latest_release() {
    curl -fsSL --retry 3 "https://api.github.com/repos/$UPSTREAM/releases/latest" \
        | grep '"tag_name"' \
        | sed -E 's/.*"tag_name": *"v?([0-9]+\.[0-9]+\.[0-9]+)".*/\1/' \
        | head -1
}

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(latest_release)"
    echo "Sin argumento: usando la última release publicada ($VERSION)."
fi

echo "==> Versión objetivo: v$VERSION"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "versión inválida '$VERSION' (se espera X.Y.Z)"

# --- 1. ¿existe el tag aguas arriba? --------------------------------------
echo "==> Comprobando tag v$VERSION en $UPSTREAM..."
if ! git ls-remote --tags "https://github.com/$UPSTREAM.git" "refs/tags/v$VERSION" | grep -q "refs/tags/v$VERSION"; then
    die "no existe el tag 'v$VERSION' en https://github.com/$UPSTREAM"
fi

# --- 2. bump de la versión por defecto ------------------------------------
if [ "$VERSION" != "$(current_version)" ]; then
    sed -i "s/^ARG ASOBI_REF=v[0-9.]*/ARG ASOBI_REF=v$VERSION/" "$DOCKERFILE"
    echo "==> Versión por defecto actualizada a v$VERSION en $DOCKERFILE."
else
    echo "==> Ya estaba en v$VERSION; sin cambios de versión."
fi

# --- 3. commit + push ------------------------------------------------------
git add "$DOCKERFILE"
if ! git diff --cached --quiet; then
    git commit -m "asobi: bump imagen a v$VERSION"
    echo "==> Commit creado."
fi

echo "==> Push a origin/main..."
git push origin main

# --- 4. tag (dispara el workflow) ------------------------------------------
echo "==> Push del tag asobi-v$VERSION (dispara 'Build image')..."
if git tag "asobi-v$VERSION"; then
    git push origin "asobi-v$VERSION"
else
    echo "El tag asobi-v$VERSION ya existía; no se re-disparó. Usa dispatch manual o borra/recréalo si lo necesitas."
fi

# --- resumen ----------------------------------------------------------------
OWNER="$(git remote get-url origin | sed -E 's#.*github.com[:/]([^/]+)/.*#\1#')"
OWNER="${OWNER,,}"
IMAGE_BASE="ghcr.io/${OWNER}/asobi-terrain-image"

echo
echo "Build lanzado. Cuando el run de 'Build image' termine en success:"
echo "  docker pull ${IMAGE_BASE}:v${VERSION}"
