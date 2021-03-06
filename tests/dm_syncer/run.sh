#!/bin/bash

set -eu

cur=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $cur/../_utils/test_prepare
WORK_DIR=$TEST_DIR/$TEST_NAME
TASK_NAME="test"

function run() {
    run_sql_file $cur/data/db1.prepare.sql $MYSQL_HOST1 $MYSQL_PORT1
    check_contains 'Query OK, 2 rows affected'
    run_sql_file $cur/data/db2.prepare.sql $MYSQL_HOST2 $MYSQL_PORT2
    check_contains 'Query OK, 3 rows affected'

    run_dm_worker $WORK_DIR/worker1 $WORKER1_PORT $cur/conf/dm-worker1.toml
    check_rpc_alive $cur/../bin/check_worker_online 127.0.0.1:$WORKER1_PORT
    run_dm_worker $WORK_DIR/worker2 $WORKER2_PORT $cur/conf/dm-worker2.toml
    check_rpc_alive $cur/../bin/check_worker_online 127.0.0.1:$WORKER2_PORT
    run_dm_master $WORK_DIR/master $MASTER_PORT $cur/conf/dm-master.toml
    check_rpc_alive $cur/../bin/check_master_online 127.0.0.1:$MASTER_PORT

    # start a task in `full` mode
    cat $cur/conf/dm-task.yaml > $WORK_DIR/dm-task.yaml
    dmctl_start_task $WORK_DIR/dm-task.yaml

    check_sync_diff $WORK_DIR $cur/conf/diff_config.toml

    dmctl_stop_task $TASK_NAME

    run_sql_file $cur/data/db1.increment.sql $MYSQL_HOST1 $MYSQL_PORT1
    run_sql_file $cur/data/db2.increment.sql $MYSQL_HOST2 $MYSQL_PORT2

    # start a task in `incremental` mode
    # using account with limited privileges
    kill_dm_worker
    run_sql_file $cur/data/db1.prepare.user.sql $MYSQL_HOST1 $MYSQL_PORT1
    check_count 'Query OK, 0 rows affected' 7
    run_sql_file $cur/data/db2.prepare.user.sql $MYSQL_HOST2 $MYSQL_PORT2
    check_count 'Query OK, 0 rows affected' 7

    cat $cur/conf/dm-syncer-1.toml > $WORK_DIR/dm-syncer-1.toml
    cat $cur/conf/dm-syncer-2.toml > $WORK_DIR/dm-syncer-2.toml
    cat $cur/conf/old_meta_file > $WORK_DIR/old_meta_file
    name1=$(grep "Log: " $WORK_DIR/worker1/dumped_data.$TASK_NAME/metadata|awk -F: '{print $2}'|tr -d ' ')
    pos1=$(grep "Pos: " $WORK_DIR/worker1/dumped_data.$TASK_NAME/metadata|awk -F: '{print $2}'|tr -d ' ')
    name2=$(grep "Log: " $WORK_DIR/worker2/dumped_data.$TASK_NAME/metadata|awk -F: '{print $2}'|tr -d ' ')
    pos2=$(grep "Pos: " $WORK_DIR/worker2/dumped_data.$TASK_NAME/metadata|awk -F: '{print $2}'|tr -d ' ')
    sed -i "s/binlog-name-placeholder-1/\"$name1\"/g" $WORK_DIR/dm-syncer-1.toml
    sed -i "s/binlog-pos-placeholder-1/$pos1/g" $WORK_DIR/dm-syncer-1.toml
    sed -i "s/binlog-name-placeholder-2/\"$name2\"/g" $WORK_DIR/old_meta_file
    sed -i "s/binlog-pos-placeholder-2/$pos2/g" $WORK_DIR/old_meta_file
    sleep 2
    run_dm_syncer $WORK_DIR/syncer1 $WORK_DIR/dm-syncer-1.toml
    meta_file=$WORK_DIR/old_meta_file
    run_dm_syncer $WORK_DIR/syncer2 $WORK_DIR/dm-syncer-2.toml $meta_file --old-config-format

    check_sync_diff $WORK_DIR $cur/conf/diff_config.toml
}

cleanup_data $TEST_NAME
# also cleanup dm processes in case of last run failed
cleanup_process $*
run $*
cleanup_process $*

echo "[$(date)] <<<<<< test case $TEST_NAME success! >>>>>>"
