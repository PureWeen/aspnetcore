#!/usr/bin/env bash
set -eo pipefail
root=$(realpath "${1:?Usage: produce.sh <scratch root>}")
cd "$root/aspnetcore"
export DISABLE_CUSTOM_PROMPT=1
source ./activate.sh
set -u
test "$(git rev-parse --is-shallow-repository)" = false
guidance=cbf730f5cd0bf8c04bf94e4f3869d6898065f37a
mkdir -p "$root/spec/bundles"
git init --bare --quiet "$root/objects.git"
commits=(
    "$guidance"
    144d56efebd32408e60cb9ec16ed521a9db36d31
    652bc2b13f910b1b1fb4e5efb4b5ebc0b14d6047
    719c33f7bf717f94b53abb8dcee7d8e793e287ba
    405bb089835ba4f908e0b5038c42fca2c4bb84de
    25e9e14f7fb51b3c20aa544b55afec70a212abb3
    f7d14ca402e8bb350148bfb64ad873e48c44f0b7
)
trees=()
for commit in "${commits[@]}"; do
    trees+=("$(git rev-parse --verify "$commit^{tree}")")
done
{
    printf '%s\n' "${commits[@]}"
    git rev-list --objects --no-object-names "${trees[@]}"
} | git pack-objects "$root/objects.git/objects/pack/pack"

produce() {
    test "$(git merge-base --all "$2" "$3")" = "$4"
    dotnet run .github/skills/review-pull-request/scripts/prepare-review.cs -- \
        --code-only --repo dotnet/aspnetcore --pr "$1" --head "$2" \
        --base-tip "$3" --merge-base "$4" --base-ref main \
        --guidance "dotnet/aspnetcore@$guidance" --objects "$root/objects.git" \
        --output "$root/spec/bundles/pr$1"
}

produce 60724 144d56efebd32408e60cb9ec16ed521a9db36d31 652bc2b13f910b1b1fb4e5efb4b5ebc0b14d6047 719c33f7bf717f94b53abb8dcee7d8e793e287ba
produce 69871 405bb089835ba4f908e0b5038c42fca2c4bb84de 25e9e14f7fb51b3c20aa544b55afec70a212abb3 f7d14ca402e8bb350148bfb64ad873e48c44f0b7
