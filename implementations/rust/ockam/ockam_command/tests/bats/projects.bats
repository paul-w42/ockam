#!/bin/bash

# ===== SETUP

setup_file() {
  load load/base.bash
  load load/orchestrator.bash
  load_orchestrator_data
}

setup() {
  load load/base.bash
  load load/orchestrator.bash
  load_bats_ext
  setup_home_dir
  skip_if_orchestrator_tests_not_enabled
  copy_orchestrator_data
}

teardown() {
  teardown_home_dir
}

# ===== TESTS

@test "projects - list" {
  run "$OCKAM" project list
  assert_success
}

@test "projects - enrollment" {
  ENROLLED_OCKAM_HOME=$OCKAM_HOME

  setup_home_dir
  NON_ENROLLED_OCKAM_HOME=$OCKAM_HOME

  run --separate-stderr "$OCKAM" identity create green
  assert_success
  green_identifier=$($OCKAM identity show green)

  run --separate-stderr "$OCKAM" identity create blue
  assert_success
  blue_identifier=$($OCKAM identity show blue)

  # They haven't been added by enroller yet
  run "$OCKAM" project authenticate --identity green --project-path "$PROJECT_JSON_PATH"
  assert_failure

  OCKAM_HOME=$ENROLLED_OCKAM_HOME
  $OCKAM project enroll --member "$green_identifier" --attribute role=member
  blue_token=$($OCKAM project enroll --attribute role=member)
  OCKAM_HOME=$NON_ENROLLED_OCKAM_HOME

  echo "OCKAM_HOME=$OCKAM_HOME;PROJECT=$(project_json_path)"

  # Green' identity was added by enroller
  run "$OCKAM" project authenticate --identity green --project-path "$PROJECT_JSON_PATH"
  assert_success
  assert_output --partial "$green_identifier"

  # For blue, we use an enrollment token generated by enroller
  run "$OCKAM" project authenticate --identity blue --token "$blue_token" --project-path "$PROJECT_JSON_PATH"
  assert_success
  assert_output --partial "$blue_identifier"
  OCKAM_HOME=$ENROLLED_OCKAM_HOME
}

@test "projects - access requiring credentials" {
  skip_if_long_tests_not_enabled
  ENROLLED_OCKAM_HOME=$OCKAM_HOME

  # Create new project and export it
  space_name=$(random_str)
  project_name=$(random_str)
  run "$OCKAM" space create "${space_name}"
  assert_success
  run "$OCKAM" project create "${space_name}" "${project_name}"
  assert_success
  $OCKAM project information "${project_name}" --output json  > "$ENROLLED_OCKAM_HOME/${project_name}_project.json"

  # Change to a new home directory where there are no enrolled identities
  setup_home_dir
  NON_ENROLLED_OCKAM_HOME=$OCKAM_HOME

  # Create identities
  run "$OCKAM" identity create green
  run "$OCKAM" identity create blue
  green_identifier=$($OCKAM identity show green)
  blue_identifier=$($OCKAM identity show blue)

  # Create nodes for the non-enrolled identities using the exported project information
  run "$OCKAM" node create green --project "$ENROLLED_OCKAM_HOME/${project_name}_project.json" --identity green
  assert_success
  run "$OCKAM" node create blue --project "$ENROLLED_OCKAM_HOME/${project_name}_project.json" --identity blue
  assert_success

  # Blue can't create forwarder as it isn't a member
  fwd=$(random_str)
  run "$OCKAM" forwarder create "$fwd" --at "/project/${project_name}" --to /node/blue
  assert_failure

  # Add green as a member
  OCKAM_HOME=$ENROLLED_OCKAM_HOME
  run "$OCKAM" project enroll --member "$green_identifier" --to "/project/${project_name}/service/authenticator" --attribute role=member
  assert_success

  # Now green can access project' services
  OCKAM_HOME=$NON_ENROLLED_OCKAM_HOME
  fwd=$(random_str)
  run "$OCKAM" forwarder create "$fwd" --at "/project/${project_name}" --to /node/green
  assert_success

  # Remove project and space
  OCKAM_HOME=$ENROLLED_OCKAM_HOME
  run "$OCKAM" project delete "${space_name}" "${project_name}"
  assert_success
  run "$OCKAM" space delete "${space_name}"
  assert_success
}

@test "projects - send a message to a project node from an embedded node, enrolled member on different install" {
  skip  # FIXME  how to send a message to a project m1 is enrolled to?  (with m1 being on a different install
        #       than the admin?.  If we pass project' address directly (instead of /project/ thing), would
        #       it present credentials? would read authority info from project.json?

  $OCKAM project information --output json  > /tmp/project.json

  export OCKAM_HOME=/tmp/ockam
  $OCKAM identity create m1
  $OCKAM identity create m2
  m1_identifier=$($OCKAM identity show m1)

  unset OCKAM_HOME
  $OCKAM project enroll --member $m1_identifier --attribute role=member

  export OCKAM_HOME=/tmp/ockam
  # m1' identity was added by enroller
  run $OCKAM project authenticate --identity m1 --project-path "$PROJECT_JSON_PATH"

  # m1 is a member,  must be able to contact the project' service
  run --separate-stderr $OCKAM message send --identity m1 --project-path "$PROJECT_JSON_PATH" --to /project/default/service/echo hello
  assert_success
  assert_output "hello"

  # m2 is not a member,  must not be able to contact the project' service
  run --separate-stderr $OCKAM message send --identity m2 --project-path "$PROJECT_JSON_PATH" --to /project/default/service/echo hello
  assert_failure
}

@test "projects - list addons" {
  run --separate-stderr "$OCKAM" project addon list --project default
  assert_success
  assert_output --partial "Id: okta"
}

@test "projects - enable and disable addons" {
  skip # TODO: wait until cloud has the influxdb and confluent addons enabled

  run --separate-stderr "$OCKAM" project addon list --project default
  assert_success
  assert_output --partial --regex "Id: okta\n +Enabled: false"
  assert_output --partial --regex "Id: confluent\n +Enabled: false"

  run --separate-stderr "$OCKAM" project addon enable okta --project default --tenant tenant --client-id client_id --cert cert
  assert_success
  run --separate-stderr "$OCKAM" project addon enable confluent --project default --bootstrap-server bootstrap-server.confluent:9092 --api-key ApIkEy --api-secret ApIsEcrEt
  assert_success

  run --separate-stderr "$OCKAM" project addon list --project default
  assert_success
  assert_output --partial --regex "Id: okta\n +Enabled: true"
  assert_output --partial --regex "Id: confluent\n +Enabled: true"

  run --separate-stderr "$OCKAM" project addon disable --addon okta --project default
  run --separate-stderr "$OCKAM" project addon disable --addon  --project default
  run --separate-stderr "$OCKAM" project addon disable --addon confluent --project default

  run --separate-stderr "$OCKAM" project addon list --project default
  assert_success
  assert_output --partial --regex "Id: okta\n +Enabled: false"
  assert_output --partial --regex "Id: confluent\n +Enabled: false"
}

@test "influxdb lease manager" {
  # TODO add more tests
  #      responsible, and that a member enrolled on a different ockam install can access it.
  skip_if_influxdb_test_not_enabled

  run "$OCKAM" project addon configure influxdb  --org-id "${INFLUXDB_ORG_ID}" --token "${INFLUXDB_TOKEN}" --endpoint-url "${INFLUXDB_ENDPOINT}" --max-ttl 60 --permissions "${INFLUXDB_PERMISSIONS}"
  assert_success

  sleep 30 #FIXME  workaround, project not yet ready after configuring addon

  $OCKAM project information default --output json  > /tmp/project.json

  export OCKAM_HOME=/tmp/ockam
  run "$OCKAM" identity create m1
  run "$OCKAM" identity create m2
  run "$OCKAM" identity create m3

  m1_identifier=$($OCKAM identity show m1)
  m2_identifier=$($OCKAM identity show m2)

  unset OCKAM_HOME
  $OCKAM project enroll --member $m1_identifier --attribute service=sensor
  $OCKAM project enroll --member $m2_identifier --attribute service=web

  export OCKAM_HOME=/tmp/ockam

  # m1 and m2 identity was added by enroller
  run "$OCKAM" project authenticate --identity m1 --project-path "$PROJECT_JSON_PATH"
  assert_success
  assert_output --partial $green_identifier

  run "$OCKAM" project authenticate --identity m2 --project-path "$PROJECT_JSON_PATH"
  assert_success
  assert_output --partial $green_identifier


  # m1 and m2 can use the lease manager
  run "$OCKAM" lease --identity m1 --project-path "$PROJECT_JSON_PATH" create
  assert_success
  run "$OCKAM" lease --identity m2 --project-path "$PROJECT_JSON_PATH" create
  assert_success

  # m3 can't
  run "$OCKAM" lease --identity m3 --project-path "$PROJECT_JSON_PATH" create
  assert_failure

  unset OCKAM_HOME
  run "$OCKAM" project addon configure influx-db  --org-id "${INFLUXDB_ORG_ID}" --token "${INFLUXDB_TOKEN}" --endpoint-url "${INFLUXDB_ENDPOINT}" --max-ttl 60 --permissions "${INFLUXDB_PERMISSIONS}" --user-access-role '(= subject.service "sensor")'
  assert_success

  sleep 30 #FIXME  workaround, project not yet ready after configuring addon

  export OCKAM_HOME=/tmp/ockam
  # m1 can use the lease manager (it has a service=sensor attribute attested by authority)
  run "$OCKAM" lease --identity m1 --project-path "$PROJECT_JSON_PATH" create
  assert_success

  # m2 can't use the  lease manager now (it doesn't have a service=sensor attribute attested by authority)
  run "$OCKAM" lease --identity m2 --project-path "$PROJECT_JSON_PATH" create
  assert_failure
}