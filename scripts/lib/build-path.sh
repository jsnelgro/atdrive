# Sourced (not run) by the scripts that build, from the project root.
#
# SwiftPM's build caches record the folder they were built in: the precompiled modules, in
# particular. In a moved or copied project the build then fails with errors like "precompiled
# file … was compiled with module cache path …" and "missing required module 'SwiftShims'".
# So the folder is noted in .build, and if it changed, the build is cleaned first. The
# dependencies' checkouts stay, so nothing is downloaded again.
#
# A .build from before this note was kept can't be checked: its folder is noted, and if it had
# moved, `swift package clean` fixes it once.
build_path_marker=.build/project-path
build_path_here=$(pwd -P)
if [[ -f "$build_path_marker" ]]; then
    build_path_before=$(<"$build_path_marker")
    if [[ "$build_path_before" != "$build_path_here" ]]; then
        echo "The project was built in $build_path_before before: cleaning the build first." >&2
        swift package clean
    fi
fi
mkdir -p .build
printf '%s\n' "$build_path_here" >"$build_path_marker"
unset build_path_marker build_path_here build_path_before
