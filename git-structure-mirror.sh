#!/bin/bash
set -Eeuxo pipefail

# Copyright 2022, Gaurav Juvekar
# SPDX-License-Identifier: MIT

src_git="--git-dir=$1"
dst_git="$2"

notes_src_template='Structure-mirror-commit: '
commit_dst_template='Source-commit: '


function pcre_escape {
  sed 's/[^\^]/[&]/g;s/[\^]/\\&/g' <<< "$*"
}

function configure_src {
  git "${src_git}" config --local notes.rewrite.amend false
  git "${src_git}" config --local notes.rewrite.rebase false
}

function repo_commit_exists {
  local repo="$1"
  local commit="$2"
  git "${repo}" cat-file -e "${commit}"
}

function src_commit_to_dst {
  local src_commit="$1"
  git "${src_git}" notes show "${src_commit}" | \
    grep -Po '(?<=^'"$(pcre_escape "${notes_src_template}")"')[0-9a-f]{40}'
}

function dst_commit_to_src {
  local dst_commit="$1"
  git "${dst_git}" cat-file -p "${dst_commit}" | \
    grep -Po '(?<=^'"$(pcre_escape "${commit_dst_template}")"')[0-9a-f]{40}'
}

function repo_get_actionable_refs {
  local repo="$1"
  cat <(git "${repo}" for-each-ref --format='%(refname)' 'refs/heads') \
      <(git "${repo}" for-each-ref --format='%(refname)' 'refs/tags')
}

repo_get_actionable_refs "${src_git}"
