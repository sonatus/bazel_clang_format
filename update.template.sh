#!/usr/bin/env bash
set -euo pipefail

bazel=bazel # TODO: I guess

function stale()
{
echo "$1" \
      | grep "ERROR: action 'ClangFormat" \
      | sed "s/^ERROR: action 'ClangFormat \(.*\)\.clang_format' is not up-to-date$/\1/" || true
}

bazel_query=("$bazel" query \
                      --color=yes \
                      --noshow_progress \
                      --ui_event_filters=-info)

bazel_format=("$bazel" build \
                    --noshow_progress \
                    --ui_event_filters=-info,-stdout \
                    --color=no \
                    --aspects=@@WORKSPACE@//:defs.bzl%clang_format_aspect \
                    --@@WORKSPACE@//:binary=@BINARY@ \
                    --@@WORKSPACE@//:config=@CONFIG@ \
                    --@@WORKSPACE@//:ignore=@IGNORE@ \
                    --output_groups=report)

bazel_format_file=("${bazel_format[@]}" --compile_one_dependency)

cd $BUILD_WORKSPACE_DIRECTORY

relpath=${BUILD_WORKING_DIRECTORY#"$BUILD_WORKSPACE_DIRECTORY"}
if [[ -n $relpath ]]; then
    relpath=${relpath#"/"}/
fi

args=$(printf " union $relpath%s" "${@}" | sed "s/^ union \(.*\)/\1/")

source_files=$("${bazel_query[@]}" \
    "let t = kind(\"cc_.* rule\", ${args:-//...} except deps(@IGNORE@, 1)) in kind(\"source file\", labels(srcs, \$t)) union kind(\"source file\", labels(hdrs, \$t))")

"$bazel" build @BINARY@

result=$("${bazel_format_file[@]}" \
             --keep_going \
             --check_up_to_date \
             $source_files 2>&1 || true)

files=$(stale "$result")

if [[ -z $files ]] && [[ $(echo "$result" | grep "ERROR:"  | wc -l) -gt 0 ]]; then
    echo "$result"
    exit 1
fi

file_count=$(echo "$files" | sed '/^\s*$/d' | wc -l)

[[ $file_count -ne 0 ]] || exit 0

# use bazel to generate the formatted files in a separate
# directory in case the user is overriding .clang-format
[[ $file_count -eq 0 ]] || "${bazel_format_file[@]}" --@@WORKSPACE@//:dry_run=False $files 2> /dev/null

for arg in $(echo "$files"); do
    generated="@BINDIR@${arg}.clang_format"
    if [[ ! -f "$generated" ]]; then
        continue
    fi

    # fix file mode bits
    # https://github.com/bazelbuild/bazel/issues/2888
    chmod $(stat -c "%a" "$arg") "$generated"

    # replace source with formatted version
    mv "$generated" "$arg"
done

# run format check to cache success
[[ $file_count -eq 0 ]] || "${bazel_format_file[@]}" $files 2> /dev/null
