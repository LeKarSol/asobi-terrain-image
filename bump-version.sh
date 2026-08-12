#!/usr/bin/env bash
set -euo pipefail

# bump-version.sh — bump de la imagen de asobi y lanzamiento del build en CI.
#
#  1. Comprueba que el tag v<VERSION> existe en widgrensit/asobi.
#  2. Sube la versión por defecto en el Dockerfile.
#  2b. Si --force, actualiza .rebuild-trigger (cache-bust selectivo).
#  3. Commit + push.
#  4. Push del tag asobi-v<VERSION> (dispara el workflow 'Build image').
#
# Uso:
#   ./bump-version.sh [--force|-f] [X.Y.Z]
#
#   Sin argumento de versión: usa la última release publicada.
#   --force / -f: si el tag asobi-v<VERSION> ya existe (local y/o remoto),
#     lo borra y lo vuelve a crear apuntando al HEAD actual, para
#     re-disparar el workflow 'Build image' sin tener que subir de
#     versión. Además actualiza .rebuild-trigger para forzar un build
#     de verdad (bypass de la cache de Buildx desde el clone en
#     adelante) - sin esto, un --force con la misma ASOBI_REF y los
#     mismos providers reutiliza toda la cache y no cambia ningún
#     layer, aunque el workflow sí se re-ejecute.

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

# --- parseo de argumentos --------------------------------------------------
FORCE_TAG=false
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --force|-f)
            FORCE_TAG=true
            ;;
        --help|-h)
            echo "Uso: $0 [--force|-f] [X.Y.Z]"
            exit 0
            ;;
        -*)
            die "opción desconocida: $arg (usa --force/-f)"
            ;;
        *)
            POSITIONAL+=("$arg")
            ;;
    esac
done

VERSION="${POSITIONAL[0]:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(latest_release)"
    echo "Sin argumento: usando la última release publicada ($VERSION)."
fi

echo "==> Versión objetivo: v$VERSION"
[ "$FORCE_TAG" = true ] && echo "==> --force activo: se recreará el tag aunque ya exista."

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

# --- 2b. cache-bust si --force ----------------------------------------
# Sin esto, --force solo re-dispara el workflow pero el build en sí
# reutiliza toda la cache de Buildx (cache-from: type=gha) si ASOBI_REF
# y providers/*.erl no cambiaron - por eso "no cambia ningún layer".
# Al tocar este archivo, el Dockerfile invalida la cache desde el COPY
# de .rebuild-trigger en adelante (ver Dockerfile), forzando un rebuild
# real del clone + providers + compile, sin desactivar la cache entera.
REBUILD_TRIGGER=".rebuild-trigger"
if [ "$FORCE_TAG" = true ]; then
    date -u +"%Y-%m-%dT%H:%M:%SZ forzado por --force (v$VERSION)" > "$REBUILD_TRIGGER"
    echo "==> --force: $REBUILD_TRIGGER actualizado para invalidar la cache de Docker."
fi

# --- 3. commit + push ------------------------------------------------------
git add "$DOCKERFILE"
[ "$FORCE_TAG" = true ] && git add "$REBUILD_TRIGGER"

MSG="asobi: bump imagen a v$VERSION"
[ "$FORCE_TAG" = true ] && MSG="$MSG (rebuild forzado)"

if ! git diff --cached --quiet; then
    git commit -m "$MSG"
    echo "==> Commit creado."
else
    echo "==> Sin cambios que commitear."
fi

echo "==> Push a origin/main..."
git push origin main

# --- 4. tag (dispara el workflow) ------------------------------------------
TAG="asobi-v$VERSION"

if [ "$FORCE_TAG" = true ]; then
    echo "==> --force: borrando tag $TAG (local y remoto) si existe..."
    git tag -d "$TAG" 2>/dev/null && echo "    tag local borrado." || echo "    no había tag local."
    if git ls-remote --tags origin "refs/tags/$TAG" | grep -q "refs/tags/$TAG"; then
        git push origin ":refs/tags/$TAG"
        echo "    tag remoto borrado."
    else
        echo "    no había tag remoto."
    fi
fi

echo "==> Push del tag $TAG (dispara 'Build image')..."
if git tag "$TAG"; then
    git push origin "$TAG"
else
    if [ "$FORCE_TAG" = true ]; then
        die "no se pudo recrear el tag $TAG tras borrarlo - revisa manualmente (git tag -l '$TAG'; git ls-remote --tags origin '$TAG')"
    fi
    echo "El tag $TAG ya existía; no se re-disparó. Usa --force para borrarlo y recrearlo apuntando al HEAD actual."
fi

# --- resumen ----------------------------------------------------------------
OWNER="$(git remote get-url origin | sed -E 's#.*github.com[:/]([^/]+)/.*#\1#')"
OWNER="${OWNER,,}"
IMAGE_BASE="ghcr.io/${OWNER}/asobi-terrain-image"

echo
echo "Build lanzado. Cuando el run de 'Build image' termine en success:"
echo "  docker pull ${IMAGE_BASE}:v${VERSION}"
