#!/usr/bin/env bash

# Handle updates and upgrades.
__should_update=0

# __should_update=0: No update needed or versions are the same.
# __should_update=1: Higher patch version.
# __should_update=2: Higher minor, major, or lexicographically greater suffix.

compare_versions() {
    current=$1
    new=$2
    echo "comparing ${current} and ${new}"

    # Remove leading 'v' if present
    ver_current="${current#v}"
    ver_new="${new#v}"

    # Extract major and minor from the first two dot-separated fields
    major_current=$(echo "$ver_current" | cut -d. -f1)
    minor_current=$(echo "$ver_current" | cut -d. -f2)
    major_new=$(echo "$ver_new" | cut -d. -f1)
    minor_new=$(echo "$ver_new" | cut -d. -f2)

    # For the third field, we might have patch plus possible suffix
    patch_part_current=$(echo "$ver_current" | cut -d. -f3)
    patch_part_new=$(echo "$ver_new" | cut -d. -f3)

    # Now split the patch from the suffix at the first dash
    patch_current="${patch_part_current%%-*}"
    suffix_current="${patch_part_current#*-}"
    if [ "$suffix_current" = "$patch_part_current" ]; then
        # Means there was no dash
        suffix_current=""
    fi

    patch_new="${patch_part_new%%-*}"
    suffix_new="${patch_part_new#*-}"
    if [ "$suffix_new" = "$patch_part_new" ]; then
        suffix_new=""
    fi

    # Convert major/minor/patch to numbers
    major_current=$((major_current))
    minor_current=$((minor_current))
    patch_current=$((patch_current))

    major_new=$((major_new))
    minor_new=$((minor_new))
    patch_new=$((patch_new))

    # Compare major/minor/patch
    if [ "$major_new" -gt "$major_current" ]; then
        __should_update=2
        return
    elif [ "$major_new" -lt "$major_current" ]; then
        __should_update=0
        return
    fi

    if [ "$minor_new" -gt "$minor_current" ]; then
        __should_update=2
        return
    elif [ "$minor_new" -lt "$minor_current" ]; then
        __should_update=0
        return
    fi

    if [ "$patch_new" -gt "$patch_current" ]; then
        __should_update=2
        return
    elif [ "$patch_new" -lt "$patch_current" ]; then
        __should_update=0
        return
    fi

    # If major/minor/patch are identical, check suffix difference
    if [ "$suffix_current" != "$suffix_new" ]; then
        __should_update=1
        return
    fi

    # Otherwise, exact match
    __should_update=0
}

# Example usage
compare_versions "v6.0.0" "v6.0.1"
echo $__should_update # should be 2
echo "expected: 2"

compare_versions "v6.0.0" "v6.0.0-hotfix"
echo $__should_update # should be 1
echo "expected: 1"

compare_versions "v6.0.0-hotfix" "v6.0.0-hotfix-3"
echo $__should_update # should be 1
echo "expected: 1"

compare_versions "v6.0.0-hotfix-3" "v6.0.1"
echo $__should_update # should be 2
echo "expected: 2"

compare_versions "v6.0.1" "v6.0.1-hotfix-rpc-9"
echo $__should_update # should be 1
echo "expected: 1"

compare_versions "v6.0.1-hotfix-rpc-9" "v6.0.1-hotfix-rpc-10"
echo $__should_update # should be 1
echo "expected: 1"

compare_versions "v6.0.1-hotfix-rpc-9" "v6.0.1-hotfix-rpc-13"
echo $__should_update # should be 1
echo "expected: 1"

compare_versions "v6.0.1-hotfix-rpc-10" "v6.0.2"
echo $__should_update # should be 2
echo "expected: 2"

compare_versions "v6.0.2" "v6.0.3"
echo $__should_update # should be 2
echo "expected: 2"

echo "# __should_update=0: No update needed or versions are the same.
# __should_update=1: Higher patch version.
# __should_update=2: Higher minor or major version."
