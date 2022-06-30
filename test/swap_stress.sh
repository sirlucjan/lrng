#!/bin/bash
#
# Copyright (C) 2017 - 2020, Stephan Mueller <smueller@chronox.de>
#
# License: see LICENSE file in root directory
#
# THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, ALL OF
# WHICH ARE HEREBY DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
# OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
# BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
# USE OF THIS SOFTWARE, EVEN IF NOT ADVISED OF THE POSSIBILITY OF SUCH
# DAMAGE.
#
# Stress test for swapping DRNG implementations to verify swapping and locking
# is correct
#
# To conduct testing, the kernel must be compiled with the following options:
#
# CONFIG_LRNG_DRNG_SWITCH=y
# CONFIG_LRNG_DRBG=m
# CONFIG_LRNG_DRNG_KCAPI=m
# CONFIG_CRYPTO_ANSI_CPRNG=m
#

# Count the available NUMA nodes
NUMA_NODES=$(cat /proc/lrng_type  | grep instance | cut -d":" -f 2)
DRBG_SKIP=0
KCAPI_SKIP=0

urandom=0
lrng_type=0
dd_random=0
dd_random_pr=0
dd_lrng=0
kcapi_hash=0

init() {
	modinfo lrng_drng_drbg > /dev/null 2>&1
	DRBG_SKIP=$?

	modinfo lrng_drng_kcapi > /dev/null 2>&1
	KCAPI_SKIP=$?

	modinfo ansi_cprng > /dev/null 2>&1
	KCAPI_SKIP=$((KCAPI_SKIP+$?))

	if [ $DRBG_SKIP -ne 0 -a $KCAPI_SKIP -ne 0 ]
	then
		echo "No DRNG switchable modules found, test cannot be performed"
		exit 1
	fi
}

# Cleanup
cleanup() {
	i=0
	while [ $i -lt $urandom ]
	do
		eval kill=\$dd_urandom_$i
		kill $kill > /dev/null 2>&1
		i=$(($i+1))
	done

	if [ $dd_random -gt 0 ]
	then
		kill $dd_random > /dev/null 2>&1
	fi

	if [ $dd_random_pr -gt 0 ]
	then
		kill $dd_random_pr > /dev/null 2>&1
	fi

	if [ $dd_lrng -gt 0 ]
	then
		kill $dd_lrng > /dev/null 2>&1
	fi

	if [ $kcapi_hash -gt 0 ]
	then
		kill $kcapi_hash > /dev/null 2>&1
	fi

	i=0
	while [ $i -lt $lrng_type ]
	do
		eval kill=\$dd_lrng_$i
		kill $kill > /dev/null 2>&1
		i=$(($i+1))
	done
}

load_drbg() {
	type=$1

	modprobe lrng_drng_drbg lrng_drbg_type=$type
	rng_name=$(cat /proc/lrng_type  | grep "DRNG name" | cut -d ":" -f2)
	rmmod lrng_drng_drbg
	rng_name="DRBG LRNG:$rng_name"
}

load_kcapi() {
	modprobe lrng_drng_kcapi drng_name="$ANSI_CPRNG" pool_hash="sha512" seed_hash="sha384"
	rng_name=$(cat /proc/lrng_type  | grep "DRNG name" | cut -d ":" -f2)
	rmmod lrng_drng_kcapi
	rng_name="KCAPI LRNG:$rng_name"
}

trap "cleanup; exit $?" 0 1 2 3 15

init

# Start reading for all DRNGs on all NUMA nodes - this ensures that all sdrngs
# instances are under active use and locks are taken
while [ $urandom -lt $NUMA_NODES ]
do
	echo "spawn load on /dev/urandom"
	( dd if=/dev/urandom of=/dev/null bs=4096 > /dev/null 2>&1) &
	eval dd_urandom_$urandom=$!
	urandom=$(($urandom+1))
done

# Enable the following for full testing, but it slows testing down considerably
# Write data into interfaces for triggering reseed and write into aux pool:
#echo "spawn write load on /dev/urandom"
#( dd if=/dev/urandom of=/dev/urandom bs=33 > /dev/null 2>&1 ) &
#eval dd_urandom_$urandom=$!
#urandom=$(($urandom+1))

# Start reading from /dev/random - ensure that the pdrng is in used and locks
# are taken
echo "spawn load on /dev/random"
( dd if=/dev/random of=/dev/null bs=4096 > /dev/null 2>&1) &
dd_random=$!

echo "spawn load on /dev/random - prediction resistance"
( dd if=/dev/random of=/dev/null bs=41 iflag=sync > /dev/null 2>&1) &
dd_random_pr=$!

if [ -c /dev/lrng ]
then
	echo "spawn load on /dev/lrng"
	( dd if=/dev/random of=/dev/null bs=4096 > /dev/null 2>&1) &
	dd_lrng=$!
fi

# lrng_type uses the crypto callbacks which implies locking - ensure that
# this code path is executed so that these locks are taken
while [ $lrng_type -lt $NUMA_NODES ]
do
	echo "spawn load on lrng_type"
	( while [ 1 ]; do cat /proc/lrng_type > /dev/null; done ) &
	eval dd_lrng_$lrng_type=$!
	lrng_type=$(($lrng_type+1))
done

DRNG_INSTANCES=$(($NUMA_NODES+1))

# Load and unload new DRNG implementations while the aforementioned
# operations are ongoing.
if [ $KCAPI_SKIP -eq 0 ]
then
	modprobe ansi_cprng > /dev/null 2>&1
	ANSI_CPRNG="ansi_cprng"
	if (cat /proc/sys/crypto/fips_enabled | grep -q 1)
	then
		ANSI_CPRNG="fips_ansi_cprng"
	fi
fi

echo "Spawning loading of hash"
( while [ 1 ]; do modprobe lrng_hash_kcapi; rmmod lrng_hash_kcapi; done ) &
eval kcapi_hash=$!

i=1
while [ $i -lt 5000 ]
do
	if [ $((i%4)) -ne 3 -a $DRBG_SKIP -eq 0 ]
	then
		load_drbg $((i%4))
	elif [ $KCAPI_SKIP -eq 0 ]
	then
		load_kcapi
	else
		load_drbg 0
	fi
	if [ $(dmesg | grep "lrng_base: reset" | wc -l) -gt $DRNG_INSTANCES ]
	then
		echo "Reset failure"
	else
		echo "load/unload done for round $i ($rng_name)"
	fi
	i=$(($i+1))
done
