#!/bin/bash
set -Eeuxo pipefail

# Copyright 2022, Gaurav Juvekar
# SPDX-License-Identifier: MIT

src_git="--git-dir=$1/.git"
dst_git="--git-dir=$2/.git"

notes_src_template='Structure-mirror-commit: '
commit_dst_template='Source-commit: '

src_already_mirrored=$(mktemp)

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

function filter_ref_if_changed {
  while read ref
  do
    if [ "x$(git ${src_git} show-ref -s ${ref})" != \
         "x$(dst_commit_to_src $(git ${dst_git} show-ref -s ${ref}))" ]
    then
      echo ${ref}
    fi
  done
}

function commit_mirror {
  local src_commit="$1"

  # Remove all ancestors that are already mirrored
  while true
  do
    local found_excludes=false
    git "${src_git}" rev-list --sparse --full-history --topo-order \
      "${src_commit}" $(cat "${src_already_mirrored}") | \
      while read commit
      do
        if src_commit_to_dst "${commit}"
        then
          found_excludes=true
          echo "^${commit}" >> "${src_already_mirrored}"
          break
        fi
      done
      if $found_excludes
      then
        break
      fi
  done


  # The resulting commit set can be mirrored in reverse-topo-order
  git "${src_git}" rev-list --sparse --full-history --reverse --topo-order \
    "${src_commit}" $(cat "${src_already_mirrored}") | \
    while read commit
    do
      local src_parents=$(git "${src_git}" show --format='%P' "${commit}" | \
        head -n1 | tr ' ' '\n')
      local dst_parents="$(cat "${src_parents}" | \
        while read commit
        do
          src_commit_to_dst "${commit}"
        done)"

      local dst_commit=$(git "${dst_git}" commit-tree $(cat "${dst_parents}" | \
        while read parent
        do
          echo -n '' -p "${parent}" ''
        done) \
          $(git "${dst_git}" write-tree) \
          -m  "$(echo "${commit_dst_template} ${commit}")")

        git "${src_git}" notes append \
          -m $(echo "${notes_src_template} ${dst_commit}") \
          "${commit}"
    done

  src_commit_to_dst "${src_commit}"
}

function ref_mirror {
  local ref="$1"

  local src_commit="$(git "${src_git}" show-ref -s "${ref}")"
  local dst_commit="$(commit_mirror "${src_commit}")"

  git "${dst_git}" update-ref "${ref}" "${dst_commit}"

  echo "^${src_commit}" >> "${src_already_mirrored}"
}


configure_src


# Delete refs that don't exist in src
comm -13 <(repo_get_actionable_refs "${src_git}") \
         <(repo_get_actionable_refs "${dst_git}") | \
  while read ref
  do
    git "${dst_git}" update-ref --delete "${ref}"
  done

# For common refs, mirror refs in dst that have changed
comm -12 <(repo_get_actionable_refs "${src_git}") \
         <(repo_get_actionable_refs "${dst_git}") | \
  filter_ref_if_changed  | \
  while read ref
  do
    ref_mirror "${ref}"
  done

#Now add missing refs
comm -23 <(repo_get_actionable_refs "${src_git}") \
         <(repo_get_actionable_refs "${dst_git}") | \
  while read ref
  do
    ref_mirror "${ref}"
  done
