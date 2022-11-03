#!/bin/bash
# Copyright 2022, Gaurav Juvekar
# SPDX-License-Identifier: MIT


# set -Eexo pipefail


src_git="--git-dir=$1/.git"
dst_git="--git-dir=$2/.git"

notes_src_template='Structure-mirror-commit: '
commit_dst_template='Source-commit: '

src_already_mirrored=$(mktemp)

function pcre_escape {
  perl -e \
    "use MIME::Base64; print quotemeta(decode_base64('$(echo -ne "$1" | base64)'));"
}

esc_notes_src_template="$(pcre_escape "${notes_src_template}")"
esc_commit_dst_template="$(pcre_escape "${commit_dst_template}")"

function configure_src {
  git "${src_git}" config --local notes.rewrite.amend false
  git "${src_git}" config --local notes.rewrite.rebase false
}


function repo_ref_to_commit {
  local repo="$1"
  local ref="$2"
  git "${repo}" show-ref -d -s "${ref}" | tail -n1 | cut -f1 -d' '
}

function repo_commit_exists {
  local repo="$1"
  local commit="$2"
  git "${repo}" cat-file -e "${commit}"
}

function src_commit_to_dst {
  local src_commit="$1"
  git "${src_git}" notes show "${src_commit}" 2>/dev/null | \
    grep -Po "(?<=^${esc_notes_src_template})[0-9a-f]{40}"
}

function dst_commit_to_src {
  local dst_commit="$1"
  git "${dst_git}" cat-file -p "${dst_commit}" | \
    grep -Po "(?<=^${esc_commit_dst_template})[0-9a-f]{40}"
}

function repo_get_actionable_refs {
  local repo="$1"
  cat <(git "${repo}" for-each-ref --format='%(refname)' 'refs/heads') \
      <(git "${repo}" for-each-ref --format='%(refname)' 'refs/tags')
}

function filter_ref_if_changed {
  while read ref
  do
    if [ "x$(repo_ref_to_commit "${src_git}" "${ref}")" != \
         "x$(dst_commit_to_src $(repo_ref_to_commit "${dst_git}" "${ref}"))" ]
    then
      echo ${ref}
    fi
  done
}

function commit_mirror {
  local src_commit="$1"

  echo Mirroring "${src_commit}" >&2

  # Remove all ancestors that are already mirrored
  tmp_rev_list="$(mktemp)"
  local found_excludes=true
  while ${found_excludes}
  do
    found_excludes=false

    git "${src_git}" rev-list --sparse --full-history --topo-order \
      "${src_commit}" $(cat "${src_already_mirrored}") > "${tmp_rev_list}"

    local len_rev_list=$(wc -l < "${tmp_rev_list}")
    echo Finding excludes in "${src_commit}" >&2
    pv -l -B41 -s "${len_rev_list}" "${tmp_rev_list}" | while read commit
    do
      # echo "Checking ${commit}" >&2
      if src_commit_to_dst "${commit}"
      then
        found_excludes=true
        echo "Already mirrored: ${commit}" >&2
        echo "^${commit}" >> "${src_already_mirrored}"
        break
      fi
    done
  done


  # The resulting commit set can be mirrored in reverse-topo-order
  git "${src_git}" rev-list --sparse --full-history --reverse --topo-order \
    "${src_commit}" $(cat "${src_already_mirrored}") > "${tmp_rev_list}"

  len_rev_list=$(wc -l < "${tmp_rev_list}")
  echo Mirroring ${len_rev_list} commits >&2

  pv -l -B41 -s ${len_rev_list} "${tmp_rev_list}" | while read commit
  do
    read -a src_parents <<< "$(git "${src_git}" show --format='%P' "${commit}" | \
      head -n1)"
    local dst_parents=$(for sp in ${src_parents[@]};\
                        do src_commit_to_dst ${sp} ;\
                        done)

    local dst_commit=$(\
      git "${dst_git}" commit-tree \
        $(for dp in ${dst_parents[@]};\
          do echo -n '' -p "${dp}"   ;\
          done) \
        $(git "${dst_git}" write-tree) \
        -m "${commit_dst_template}${commit}")

    git "${src_git}" notes append \
      -m "${notes_src_template}${dst_commit}" \
      "${commit}"
  done

  rm "${tmp_rev_list}"
  src_commit_to_dst "${src_commit}"
}

function ref_mirror {
  local ref="$1"

  echo Mirroring "${ref}" >&2

  local src_commit="$(repo_ref_to_commit "${src_git}" "${ref}")"
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
