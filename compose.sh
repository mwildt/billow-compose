billowfile='./billowfile'
context=${PWD##*/}
oldIFS=$IFS
checksum_label="billow.container.checksum"
context_label="billow.container.context"
service_name_label="billow.container.service-name"
engine="docker"
job="--"

join_by_char() {
  local IFS="$1"
  shift
  echo "$*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
     up)
       job="run"
       ;;
     stop | state | rm | run)
      job="$1"
      ;;
     --billowfile)
         billowfile=$2
         shift;
         ;;
     --podman)
       engine="podman"
       ;;
     *) echo "unkown parameter $1" >&2
       exit 1
       ;;
   esac
   shift
done

billowfilePath=$(realpath "$billowfile")

echo "start billow compose {context: $context, engine: $engine, billow-file: $billowfilePath}"
engine_status="$($engine --version 2> /dev/null)"
if [ $? -gt 0 ]; then
  echo "engine $engine not working properly."
  exit 1
fi
echo "operating with $engine"
echo "$engine_status"

process_line() {
    case "$1" in
       service)
         shift
         process_service_line "$@"
         ;;
       *) echo "unknown processor type $1" >&2
         exit 1
         ;;
     esac
}

process_service_line() {
  case "$job" in
    run)
      process_service_line_run "$@"
      ;;
    stop)
      process_service_line_stop "$@"
      ;;
    state)
      process_service_line_state "$@"
      ;;
    rm)
      process_service_line_rm "$@"
      ;;
    *) echo "Job $job is not defined for processor-type services" >&2
      exit 1
      ;;
    esac
}

process_service_line_stop() {
  service_name="$1"
  service_state=$(get_service_state $service_name)
  case "$service_state" in
    "running" )
      echo "[$service_name] shutdown service"
      $engine stop $service_name >/dev/null
      ;;
    *)
       echo "[$service_name] already stopped"
       ;;
    esac
}

process_service_line_rm() {
  service_name="$1"
  service_state=$(get_service_state $service_name)
  case "$service_state" in
    "running" | "exited" | "created")
      echo "[$service_name] remove service"
      $engine rm -f $service_name >/dev/null
      ;;
    "absent")
       echo "[$service_name] already absent"
       ;;
    *)
       echo "[$service_name] illegal state $service_state "
       ;;
    esac
}

get_service_state () {
  service_name="$1"
  service_state=$($engine inspect $service_name -f '{{.State.Status}}' 2>/dev/null)
   if [ $? -gt 0 ]; then
      echo "absent"
   else
      echo $service_state
   fi
}

get_service_checksum () {
  service_name="$1"
  container_checksum=$($engine inspect $service_name --format "{{index .Config.Labels \"$checksum_label\"}}" 2>/dev/null )
  if [ $? -gt 0 ]; then
    echo "--"
  else
    echo $container_checksum
  fi
}

process_service_line_state() {
  service_name="$1"
  service_state=$(get_service_state $service_name)
  echo "[$service_name] $service_state"
}

process_service_line_run() {
  service_name="$1"
  shift
  image="$1"
  shift
  # echo "[$service_name] run service as: $@ --name $service_name $image"

  engine_args="--label $context_label=$context --label $service_name_label=$service_name"
  while [[ $# -gt 0 ]]; do
    case "$1" in
       -v)
         IFS=':'
         volume=($2)
         volume[0]=$(realpath "${volume[0]}")
         engine_args="${engine_args} --volume $(join_by_char : ${volume[@]})"
         IFS=$oldIFS
         shift
         ;;
       -p)
          engine_args="${engine_args} -p $2"
          shift
          ;;
       --env | -e)
          engine_args="${engine_args} --env $2"
          shift
          ;;
        --env-file)
          engine_args="${engine_args} --env-file $2"
          shift
          ;;
        --label | -l)
          engine_args="${engine_args} --label $2"
          shift
          ;;
        --network)
          engine_args="${engine_args} --network $2"
          shift
          ;;
        --secret)
          engine_args="${engine_args} --secret $2"
          shift
          ;;
        --log-driver)
          engine_args="${engine_args} --log-driver $2"
          shift
          ;;
       *) echo "unkown service parameter $1" >&2
         exit 1
         ;;
     esac
     shift
  done

  docker_run_cmd="$engine run $engine_args --name $service_name $image $entry"
  config_checksum=$(echo $docker_run_cmd | sha256sum | awk '{print $1}')
  container_checksum=$(get_service_checksum $service_name)
  service_state=$(get_service_state $service_name)

   case "$service_state" in
     "absent" )
        echo "[$service_name] create service"
        $engine run -d $engine_args --name $service_name -l $checksum_label=$config_checksum $image $entry 2>&1 1>/dev/null
        ;;
     "running" )
         if [ "$config_checksum" = "$container_checksum" ]; then
            echo "[$service_name] service remains unchanged"
         else
           echo "[$service_name] recreate service"
           $engine stop $service_name >/dev/null
           $engine rm $service_name >/dev/null
           $engine run -d $engine_args --name $service_name -l $checksum_label=$config_checksum $image $entry 2>&1 1>/dev/null
         fi
         ;;
     "exited" | "created" )
        if [ "$config_checksum" = "$container_checksum" ]; then
            echo "[$service_name] start service"
            $engine start $service_name >/dev/null
        else
           echo "[$service_name] recreate service"
           $engine stop $service_name >/dev/null
           $engine rm $service_name >/dev/null
           $engine run -d $engine_args --name $service_name -l $checksum_label=$config_checksum $image $entry 2>&1 1>/dev/null
        fi
        ;;
      *)
        echo "[$service_name] illegal service state $service_state"
        ;;

    esac
}

while read line; do
  process_line $line
done < $billowfilePath