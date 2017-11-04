#!/usr/bin/env bash
#
#
# A simple Nagios command that check some statistics of a JAVA JVM.
#
# It first checks that the process specified by its pid (-p) or its
# service name (-s) (assuming there is a /var/run/<name>.pid file
# holding its pid) is running and is a java process.
# It then calls jstat -gc and jstat -gccapacity to catch current and
# maximum 'heap' and 'metaspace' sizes.
# What is called 'heap' here is the survivor(s) + eden + old generation space,
# while 'metaspace' represents the metaspace for java 1.8.
# If specified (with -w and -c options) values can be checked with
# WARNING or CRITICAL thresholds (apply to both heap and metaspace regions).
# This plugin also attach perfomance data to the output:
#  pid=<pid>
#  heap=<heap-size-used>;<heap-max-size>;<%ratio>;<warning-threshold-%ratio>;<critical-threshold-%ratio>
#  metaspace=<metaspace-size-used>;<metaspace-max-size>;<%ratio>;<warning-threshold-%ratio>;<critical-threshold-%ratio>
#
#
# Created: 2012, June
# By: Eric Blanchard
# Modified: 2017, November
# By Jani Haglund
# License: LGPL v2.1
#


# Usage helper for this script
usage() {
    typeset prog="${1:-check_jstat.sh}"
    echo "Usage: $prog -v";
    echo "       Print version and exit"
    echo "Usage: $prog -h";
    echo "      Print this help and exit"
    echo "Usage: $prog -p <pid> [-w <%ratio>] [-c <%ratio>] [-P <java-home>]";
    echo "Usage: $prog -s <service> [-w <%ratio>] [-c <%ratio>] [-P <java-home>]";
    echo "Usage: $prog -j <java-name> [-w <%ratio>] [-c <%ratio>] [-P <java-home>]";
    echo "Usage: $prog -J <java-name> [-w <%ratio>] [-c <%ratio>] [-P <java-home>]";
    echo "       -p <pid>       the PID of process to monitor"
    echo "       -s <service>   the service name of process to monitor"
    echo "       -j <java-name> the java app (see jps) process to monitor"
    echo "                      if this name in blank (-j '') any java app is"
    echo "                      looked for (as long there is only one)"
    echo "       -J <java-name> same as -j but checks on 'jps -v' output"
    echo "       -P <java-home> use this java installation path"
    echo "       -w <%>         the warning threshold ratio current/max in % (defaults to 90)"
    echo "       -c <%>         the critical threshold ratio current/max in % (defaults to 95)"
}

VERSION='1.4'
service=''
pid=''
ws=90
cs=95
use_jps=0
jps_verbose=0
java_home=''

while getopts hvp:s:j:J:P:w:c: opt ; do
    case ${opt} in
    v)  echo "$0 version $VERSION"
        exit 0
        ;;
    h)  usage $0
        exit 3
        ;;
    p)  pid="${OPTARG}"
        ;;
    s)  service="${OPTARG}"
        ;;
    j)  java_name="${OPTARG}"
        use_jps=1
        ;;
    J)  java_name="${OPTARG}"
        use_jps=1
        jps_verbose=1
        ;;
    P)  java_home="${OPTARG}"
        ;;
    w)  ws="${OPTARG}"
        ;;
    c)  cs="${OPTARG}"
        ;;
    esac
done

if [ -z "$pid" -a -z "$service" -a $use_jps -eq 0 ] ; then
    echo "One of -p, -s or -j parameter must be provided"
    usage $0
    exit 3
fi

if [ -n "$pid" -a -n "$service" ] ; then
    echo "Only one of -p or -s parameter must be provided"
    usage $0
    exit 3
fi
if [ -n "$pid" -a $use_jps -eq 1 ] ; then
    echo "Only one of -p or -j parameter must be provided"
    usage $0
    exit 3
fi
if [ -n "$service" -a $use_jps -eq 1 ] ; then
    echo "Only one of -s or -j parameter must be provided"
    usage $0
    exit 3
fi

if [ -n "${java_home}" ] ; then
    if [ -x "${java_home}/bin/jstat" ] ; then
        PATH="${java_home}/bin:${PATH}"
    else
        echo "jstat not found in ${java_home}/bin"
        usage $0
        exit 3
    fi
fi

if [ $use_jps -eq 1 ] ; then
    if [ -n "$java_name" ] ; then
        if [ "${jps_verbose}" = "1" ]; then
            java=$(jps -v | grep "$java_name" 2>/dev/null)
        else
            java=$(jps | grep "$java_name" 2>/dev/null)
        fi
    else
        java=$(jps | grep -v Jps 2>/dev/null)
    fi
    java_count=$(echo "$java" | wc -l)
    if [ -z "$java" -o "$java_count" != "1" ] ; then
        echo "UNKNOWN: No (or multiple) java app found"
        exit 3
    fi
    pid=$(echo "$java" | cut -d ' ' -f 1)
    label=${java_name:-$(echo "$java" | cut -d ' ' -f 2)}
elif [ -n "$service" ] ; then
    if [ ! -r /var/run/${service}.pid ] ; then
        echo "/var/run/${service}.pid not found"
        exit 3
    fi
    pid=$(cat /var/run/${service}.pid)
    label=$service
else
    label=$pid
fi

ps -p "$pid" > /dev/null
if [ "$?" != "0" ] ; then
    echo "CRITICAL: process pid[$pid] not found"
    exit 2
else
    if [ -d /proc/$pid ] ; then
        proc_name=$(cat /proc/$pid/status | grep 'Name:' | sed -e 's/Name:[ \t]*//')
        if [ "$proc_name" != "java" ]; then
            echo "CRITICAL: process pid[$pid] seems not to be a JAVA application"
            exit 2
        fi
    fi
fi

gcraw=$(jstat -gc $pid 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "CRITICAL: Can't get GC statistics"
    exit 2
fi
heap=$(
    echo "$gcraw" | awk '
        NR == 1 { \
            for ( i = 1; i <= NF; i++ ) { \
                f[ $i ] = i \
            } \
        } \
        NR == 2 { \
            printf ( "%d", $(f["S0U"]) + $(f["S1U"]) + $(f["EU"]) + $(f["OU"]) ) \
        }
    '
)
#echo "heap=$heap"
heapmx=$(
    echo "$gcraw" | awk '
        NR == 1 { \
            for ( i = 1; i <= NF; i++ ) { \
                f[$i] = i \
            } \
        } \
        NR == 2 { \
            printf ( "%d", $(f["S0C"]) + $(f["S1C"]) + $(f["EC"]) + $(f["OC"]) ) \
        }
    '
)
#echo "heapmx=$heapmx"

ms=$(
    echo "$gcraw" | awk '
        NR == 1 { \
            for ( i = 1; i <= NF; i++ ) { \
                f[ $i ] = i \
            } \
        } \
        NR == 2 { \
            printf ( "%d", $(f["MU"]) ) \
        }
    '
)
#echo "ms=$ms"
msraw=$(jstat -gcmetacapacity $pid 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "CRITICAL: Can't get MetaSpace statistics"
    exit 2
fi
msmx=$(
    echo "$msraw" | awk '
        NR == 1 { \
            for ( i = 1; i <= NF; i++ ) { \
                f[$i] = i \
            } \
        } \
        NR == 2 { \
            printf ( "%d", $(f["MCMX"]) ) \
        }
    '
)
#echo "msmx=$msmx"

heapratio=$((($heap * 100) / $heapmx))
metaspaceratio=$((($ms * 100) / $msmx))

heapw=$(($heapmx * $ws / 100))
heapc=$(($heapmx * $cs / 100))
metaspacew=$(($msmx * $ws / 100))
metaspacec=$(($msmx * $cs / 100))

#echo "youg+old=${heap}k, (Max=${heapmx}k, current=${heapratio}%)"
#echo "metaspace=${ms}k, (Max=${msmx}k, current=${metaspaceratio}%)"


#perfdata="pid=$pid heap=$heap;$heapmx;$heapratio;$ws;$cs metaspace=$ms;$msmx;$metaspaceratio;$ws;$cs"
#perfdata="pid=$pid"
perfdata=""
perfdata="${perfdata} heap=${heap};$heapw;$heapc;0;$heapmx"
perfdata="${perfdata} heap_ratio=${heapratio}%;$ws;$cs;0;100"
perfdata="${perfdata} metaspace=${ms};$metaspacew;$metaspacec;0;$msmx"
perfdata="${perfdata} metaspace_ratio=${metaspaceratio}%;$ws;$cs;0;100"

if [ $cs -gt 0 -a $metaspaceratio -ge $cs ]; then
    echo "CRITICAL: jstat process $label critical MetaSpace (${metaspaceratio}% of MaxMetaSpaceSize)|$perfdata"
    exit 2
fi
if [ $cs -gt 0 -a $heapratio -ge $cs ]; then
    echo "CRITICAL: jstat process $label critical Heap (${heapratio}% of MaxHeapSize)|$perfdata"
    exit 2
fi

if [ $ws -gt 0 -a $metaspaceratio -ge $ws ]; then
    echo "WARNING: jstat process $label warning MetaSpace (${metaspaceratio}% of MaxMetaSpaceSize)|$perfdata"
    exit 1
fi
if [ $ws -gt 0 -a $heapratio -ge $ws ]; then
    echo "WARNING: jstat process $label warning Heap (${heapratio}% of MaxHeapSize)|$perfdata"
    exit 1
fi
echo "OK: jstat process $label alive|$perfdata"
exit 0

# That's all folks !
