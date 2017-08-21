if [ -z "$BASH" ]; then
    ECHO=echo
else
    ECHO='echo -e'
fi
# NOTE: This requires GNU getopt.  On Mac OS X and FreeBSD, you have to install this
# separately; see below.
TEMP=`getopt -o v: --long headers:,libs:,cc:,cxx: -n 'config_brpc' -- "$@"`

if [ $? != 0 ] ; then >&2 $ECHO "Terminating..."; exit 1 ; fi

# Note the quotes around `$TEMP': they are essential!
eval set -- "$TEMP"

# Convert to abspath always so that generated mk is include-able from everywhere
while true; do
    case "$1" in
        --headers ) HDRS_IN="$(readlink -f $2)"; shift 2 ;;
        --libs ) LIBS_IN="$(readlink -f $2)"; shift 2 ;;
        --cc ) CC=$2; shift 2 ;;
        --cxx ) CXX=$2; shift 2 ;;
        -- ) shift; break ;;
        * ) break ;;
    esac
done
if [ -z "$CC" ]; then
    if [ ! -z "$CXX" ]; then
        >&2 $ECHO "--cc and --cxx must be both set or unset"
        exit 1
    fi
    CC=gcc
    CXX=g++
elif [ -z "$CXX" ]; then
    >&2 $ECHO "--cc and --cxx must be both set or unset"
    exit 1
fi

GCC_VERSION=$($CXX tools/print_gcc_version.cc -o print_gcc_version && ./print_gcc_version && rm ./print_gcc_version)
if [ $GCC_VERSION -gt 0 ] && [ $GCC_VERSION -lt 40800 ]; then
    >&2 $ECHO "GCC is too old, please install a newer version supporting C++11"
    exit 1
fi

if [ -z "$HDRS_IN" ] || [ -z "$LIBS_IN" ]; then
    >&2 $ECHO "config_brpc: --headers=HDRPATHS --libs=LIBPATHS must be specified"
    exit 1
fi

find_dir_of_lib() {
    local lib=$(find ${LIBS_IN} -name "lib${1}.a" -o -name "lib${1}.so*" | head -n1)
    if [ ! -z "$lib" ]; then
        dirname $lib
    fi
}
find_dir_of_lib_or_die() {
    local dir=$(find_dir_of_lib $1)
    if [ -z "$dir" ]; then
        >&2 $ECHO "Fail to find $1 from --libs"
        exit 1
    else
        $ECHO $dir
    fi
}

find_bin() {
    TARGET_BIN=$(which "$1" 2>/dev/null)
    if [ ! -z "$TARGET_BIN" ]; then
        $ECHO $TARGET_BIN
    else
        find ${LIBS_IN} -name "$1" | head -n1
    fi
}
find_bin_or_die() {
    TARGET_BIN=$(find_bin "$1")
    if [ -z "$TARGET_BIN" ]; then
        >&2 $ECHO "Fail to find $1 from --libs"
        exit 1
    fi
    $ECHO $TARGET_BIN
}

find_dir_of_header() {
    find ${HDRS_IN} -path "*/$1" | head -n1 | sed "s|$1||g"
}
find_dir_of_header_or_die() {
    local dir=$(find_dir_of_header $1)
    if [ -z "$dir" ]; then
        >&2 $ECHO "Fail to find $1 from --headers"
        exit 1
    fi
    $ECHO $dir
}

# Inconvenient to check these headers in baidu-internal
#PTHREAD_HDR=$(find_dir_of_header_or_die pthread.h)
#OPENSSL_HDR=$(find_dir_of_header_or_die openssl/ssl.h)

STATIC_LINKINGS=
DYNAMIC_LINKINGS="-lpthread -lrt -lssl -lcrypto -ldl -lz"
append_linking() {
    if [ -f $1/lib${2}.a ]; then
        STATIC_LINKINGS="$STATIC_LINKINGS -l$2"
        export STATICALLY_LINKED_$2=1
    else
        DYNAMIC_LINKINGS="$DYNAMIC_LINKINGS -l$2"
        export STATICALLY_LINKED_$2=0
    fi
}

GFLAGS_LIB=$(find_dir_of_lib_or_die gflags)
append_linking $GFLAGS_LIB gflags

PROTOBUF_LIB=$(find_dir_of_lib_or_die protobuf)
append_linking $PROTOBUF_LIB protobuf

LEVELDB_LIB=$(find_dir_of_lib_or_die leveldb)
if [ -f $LEVELDB_LIB/libleveldb.a ]; then
	STATIC_LINKINGS="$STATIC_LINKINGS -lleveldb"
	# required by leveldb
	SNAPPY_LIB=$(find_dir_of_lib snappy)
	if [ ! -z "$SNAPPY_LIB" ]; then
		append_linking $SNAPPY_LIB snappy
	fi
else
	DYNAMIC_LINKINGS="$DYNAMIC_LINKINGS -lleveldb"
fi

PROTOC=$(find_bin_or_die protoc)

GFLAGS_HDR=$(find_dir_of_header_or_die gflags/gflags.h)
PROTOBUF_HDR=$(find_dir_of_header_or_die google/protobuf/message.h)
LEVELDB_HDR=$(find_dir_of_header_or_die leveldb/db.h)

HDRS=$($ECHO "$GFLAGS_HDR\n$PROTOBUF_HDR\n$LEVELDB_HDR" | sort | uniq)
LIBS=$($ECHO "$GFLAGS_LIB\n$PROTOBUF_LIB\n$LEVELDB_LIB\n$SNAPPY_LIB" | sort | uniq)

absent_in_the_list() {
    TMP=$($ECHO "`$ECHO "$1\n$2" | sort | uniq`")
    if [ "${TMP}" = "$2" ]; then
        return 1
    fi
    return 0
}

OUTPUT_CONTENT="# Generated by config_brpc.sh, don't modify manually"
append_to_output() {
    OUTPUT_CONTENT="${OUTPUT_CONTENT}\n$*"
}
# $1: libname, $2: indentation
append_to_output_headers() {
    if absent_in_the_list "$1" "$HDRS"; then
        append_to_output "${2}HDRS+=$1"
        HDRS="${HDRS}\n$1"
    fi
}
# $1: libname, $2: indentation
append_to_output_libs() {
    if absent_in_the_list "$1" "$LIBS"; then
        append_to_output "${2}LIBS+=$1"
        LIBS="${LIBS}\n$1"
    fi
}
# $1: libdir, $2: libname, $3: indentation
append_to_output_linkings() {
    if [ -f $1/lib$2.a ]; then
        append_to_output "${3}STATIC_LINKINGS+=-l$2"
        export STATICALLY_LINKED_$2=1
    else
        append_to_output "${3}DYNAMIC_LINKINGS+=-l$2"
        export STATICALLY_LINKED_$2=0
    fi
}

#can't use \n in texts because sh does not support -e
append_to_output "HDRS=$($ECHO $HDRS)"
append_to_output "LIBS=$($ECHO $LIBS)"
append_to_output "PROTOC=$PROTOC"
append_to_output "PROTOBUF_HDR=$PROTOBUF_HDR"
append_to_output "CC=$CC"
append_to_output "CXX=$CXX"
append_to_output "GCC_VERSION=$GCC_VERSION"
append_to_output "STATIC_LINKINGS=$STATIC_LINKINGS"
append_to_output "DYNAMIC_LINKINGS=$DYNAMIC_LINKINGS"

append_to_output "ifeq (\$(NEED_LIBPROTOC), 1)"
PROTOC_LIB=$(find $PROTOBUF_LIB -name "libprotoc.*" | head -n1)
if [ -z "$PROTOC_LIB" ]; then
    append_to_output "   \$(error \"Fail to find libprotoc\")"
else
    # libprotobuf and libprotoc must be linked same statically or dynamically
    # otherwise the bin will crash.
    if [ $STATICALLY_LINKED_protobuf -gt 0 ]; then
        append_to_output "    STATIC_LINKINGS+=-lprotoc"
    else
        append_to_output "    DYNAMIC_LINKINGS+=-lprotoc"
    fi
fi
append_to_output "endif"

append_to_output "ifeq (\$(NEED_GPERFTOOLS), 1)"
# required by cpu/heap profiler
TCMALLOC_LIB=$(find_dir_of_lib tcmalloc_and_profiler)
if [ -z "$TCMALLOC_LIB" ]; then
    append_to_output "    \$(error \"Fail to find gperftools\")"
else
    append_to_output_libs "$TCMALLOC_LIB" "    "
    TCMALLOC_HDR=$(find_dir_of_header_or_die google/profiler.h)
    append_to_output_headers "$TCMALLOC_HDR" "    "
    append_to_output_linkings $TCMALLOC_LIB tcmalloc_and_profiler "    "
    if [ $STATICALLY_LINKED_tcmalloc_and_profiler -gt 0 ]; then
        # required by tcmalloc('s profiler)
        UNWIND_LIB=$(find_dir_of_lib unwind)
        if [ ! -z "$UNWIND_LIB" ]; then
            append_to_output_libs $UNWIND_LIB "    "
            append_to_output_linkings $UNWIND_LIB unwind "    "
            if [ $STATICALLY_LINKED_unwind -gt 0 ]; then
                # required by libunwind
                LZMA_LIB=$(find_dir_of_lib lzma)
                if [ ! -z "$LZMA_LIB" ]; then
                    append_to_output_linkings $LZMA_LIB lzma "    "
                fi
            fi
        fi
    fi
fi
append_to_output "endif"

# required by UT
#gtest
GTEST_LIB=$(find_dir_of_lib gtest)
append_to_output "ifeq (\$(NEED_GTEST), 1)"
if [ -z "$GTEST_LIB" ]; then
    append_to_output "    \$(error \"Fail to find gtest\")"
else
    GTEST_HDR=$(find_dir_of_header_or_die gtest/gtest.h)
    append_to_output_libs $GTEST_LIB "    "
    append_to_output_headers $GTEST_HDR "    "
    append_to_output_linkings $GTEST_LIB gtest "    "
    append_to_output_linkings $GTEST_LIB gtest_main "    "
fi
append_to_output "endif"
#gmock
GMOCK_LIB=$(find_dir_of_lib gmock)
append_to_output "ifeq (\$(NEED_GMOCK), 1)"
if [ -z "$GMOCK_LIB" ]; then
    append_to_output "    \$(error \"Fail to find gmock\")"
else
    GMOCK_HDR=$(find_dir_of_header_or_die gmock/gmock.h)
    append_to_output_libs $GMOCK_LIB "    "
    append_to_output_headers $GMOCK_HDR "    "
    append_to_output_linkings $GMOCK_LIB gmock "    "
    append_to_output_linkings $GMOCK_LIB gmock_main "    "
fi
append_to_output "endif"

# write to config.mk
$ECHO "$OUTPUT_CONTENT" > config.mk
