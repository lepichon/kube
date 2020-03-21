#!/bin/bash

# requierd kubectl >= 1.11

tabs -18

declare -a MONITORED_NS
MONITORED_NS=(kube-system es-cluster infra mongo monitoring rabbitmq zipkin daas infra paas rds default)

# Refresh time after informations are collected
REFRESH_TIME=4

TEMP_LOG_FILE="/tmp/monitor_workload.$RANDOM"
KUBECTL="kubectl"

# term colors
bold=$'\e[1m'
red=$'\e[31m'
yel=$'\e[33m'
redbold=$'\e[1;31m'
yelbold=$'\e[1;33m'
end=$'\e[0m'

cleanup() {
    test -e "${TEMP_LOG_FILE}" && \
        \rm -f "${TEMP_LOG_FILE}"
    exit
}

sizehumanToBytes() {
    sizestr=$1
    echo ${sizestr} | numfmt --round=up   --to=iec --from=iec-i --to=none
}

sizeBytesToHuman() {
    echo $1 | numfmt  --round=up --from=none --to=iec-i
}

get_services() {
    svc=$1
    ${KUBECTL} get services -n $svc 2>/dev/null \
        | awk 'NR>1 {printf "%-50s %-4s %-10s %s\n", $1, $2, $3, $4}'
}

get_pods() {
    pod=$1
    ${KUBECTL} get pods -n $pod 2>/dev/null \
        | awk 'NR>1 {printf "%-50s %-4s %-10s %-10s %s\n", $1, $2, $3, $4,$5}'
}

check_k8s_connexion() {
    echo "Test cluster active connexion..."
    ${KUBECTL} get namespaces >/dev/null 2>&1
    if [ $? != 0 ]; then
        echo "!! You're not connected to k8s cluster !!"
        echo "!! Please login to the cluster and retry"
        exit 1
    fi
}

parse_item_pct() {
    val=$1
    echo "$val" | sed 's/.*(\([0-9]\+\)\%).*/\1/'
}

parse_item_val() {
    val=$1
    echo "$val" | perl -npe 's/([0-9]+)([gmki]{1,2})\s.*/$1 $2/i'
}


clear_screen() {
    printf '\033[2J'
}

compute_cluster_resources() {
    declare -A nodes_flavors
    total_size_pvc=0
    total_nodes_mem=0
    total_nodes_cpu=0
    total_nodes_cnt=0
    
    # pvc
    while read s; do 
        if [ -n "$s" ]; then
                     # add i at end of unit if mising
                     [[ $s =~ .*i$ ]] || s=$s"i"
            bytesize=$(sizehumanToBytes "$s")
        	test -z "$bytesize" && bytesize=0
        else
            bytesize=0
        fi
        total_size_pvc=$((( ${total_size_pvc} + ${bytesize} )))
    done < <(kubectl get pvc --all-namespaces \
               -o jsonpath='{.items[?(@.kind=="PersistentVolumeClaim")].status.capacity.storage}' \
               | tr ' ' '\n' && echo)
                            
    # nodes RAM
    while read s; do
        bytesize=$(sizehumanToBytes "$s")
        total_nodes_mem=$((( ${total_nodes_mem} + ${bytesize} )))
        (( total_nodes_cnt++ ))
    done < <(kubectl get nodes \
                     -o jsonpath='{.items[?(@.kind=="Node")].status.capacity.memory}' \
                     | tr ' ' '\n' && echo)
    
    # nodes vCPU
    total_nodes_cpu=$(kubectl get nodes \
                        -o jsonpath='{.items[?(@.kind=="Node")].status.capacity.cpu}' \
                        | tr ' ' '\n' \
                        | awk '{sum+=$1} END { print sum}')
    
    # nodes flavor
    while read flavor; do
        nodes_flavors[$flavor]=$((( nodes_flavors[$flavor]+1 )))
    done < <(kubectl get nodes -o=yaml| grep beta.kubernetes.io/instance-type: | awk '{print $2}')
    
    # Display results
    echo "Nodes count : ${total_nodes_cnt}" >> ${TEMP_LOG_FILE}
    echo "Total Nodes Memory : $(sizeBytesToHuman ${total_nodes_mem}) (${total_nodes_mem} bytes)" >> ${TEMP_LOG_FILE}
    echo "Total Nodes vCPUs : ${total_nodes_cpu}" >> ${TEMP_LOG_FILE}
    echo "Total PVC : $(sizeBytesToHuman ${total_size_pvc}) (${total_size_pvc} bytes)" >> ${TEMP_LOG_FILE}
    echo "Nodes flavors:" >> ${TEMP_LOG_FILE}
    for i in ${!nodes_flavors[@]}; do
        echo -e "\t- ${nodes_flavors[$i]}: $i" >> ${TEMP_LOG_FILE}
    done
}

# Define global var NODES_ITEMS_LIST (strings \n delimited)
# NODES_ITEMS_LIST=  $node  $cpu_req  $cpu_lim \t $mem_req  $mem_lim
#
get_nodes_infos() {
  NODES_ITEMS_STR=""
  NODES_ITEMS_LIST=""
  KUBE_NODES=$(${KUBECTL} get nodes -o jsonpath='{.items[?(@.kind=="Node")].metadata.name}')
  
  for node in ${KUBE_NODES}; do 
      NODES_ITEMS_STR=$(${KUBECTL} describe node ${node} | grep -A5 "Allocated" \
                                                       | egrep '\s*(cpu|memory)' \
                                                       | perl -npe 's/\s+(?:cpu|memory)\s+(.*)\n/$1 /' \
                                                       | perl -npe 's/((?:[^\s]+\s+){4})((?:[^\s]+\s+){4})/$1\t$2\n/g')
      NODES_ITEMS_LIST+=$(printf "\n%s\t" "$node   ${NODES_ITEMS_STR}")
  done
}

compute_nodes_infos() {
    # ---------------------------
    # Display Nodes informations
    #
    # Nodes columns format
    NODE_FMT="%-55s%-15s%-15s%-15s%-25s%-25s%-25s\n"
    printf "${NODE_FMT}" "=============================================" \
                         "==========" \
                         "==========" \
                         "==========" \
                         "==========" \
                         "==========" \
                         "==========" >> ${TEMP_LOG_FILE}
    printf "${bold}${NODE_FMT}${end}" "NODES Hostname" \
                                      "CPU Req" \
                                      "CPU Lim" \
                                      "CPU Lim Left" \
                                      "Memory Req" \
                                      "Memory Lim" \
                                      "Memory Lim Left" >> ${TEMP_LOG_FILE}
    printf "${NODE_FMT}" "---------------------------------------------" \
                         "----------" \
                         "----------" \
                         "----------" \
                         "----------" \
                         "----------" \
                         "----------" >> ${TEMP_LOG_FILE}
    
    let TOTAL_NODES=TOTAL_REQ_CPU_PCT=TOTAL_LIM_CPU_PCT=TOTAL_LIM_CPU_LEFT_PCT=TOTAL_REQ_MEM_PCT=TOTAL_LIM_MEM_PCT=TOTAL_LIM_MEM_LEFT_PCT=0

    for line in ${NODES_ITEMS_LIST}; do
        # split node line items columns
        node_line_items=$(echo "$line" | perl -npe 's/\s+$//' | perl -npe 's/(\s{2,}|\t)/\n/g')

        # make columns as array
        declare -a node_array_items=()
        declare -a node_all_items=()
        for node_item in ${node_line_items}; do
            node_array_items+=("${node_item}")
        done
        # calcul total resources usage percentage (excluding master)
        if ! [[ "${node_array_items[0]}" =~ master ]]; then
          TOTAL_NODES=$(expr ${TOTAL_NODES} + 1)
          
          node=${node_array_items[0]}

          # Used resources values
          cpu_req_val=$(parse_item_val "${node_array_items[1]}"  | cut -d' ' -f1)
          cpu_req_unit=$(parse_item_val "${node_array_items[1]}" | cut -d' ' -f2)
          cpu_lim_val=$(parse_item_val "${node_array_items[2]}"  | cut -d' ' -f1)
          cpu_lim_unit=$(parse_item_val "${node_array_items[2]}" | cut -d' ' -f2)
          mem_req_val=$(parse_item_val "${node_array_items[3]}"  | cut -d' ' -f1)
          mem_req_unit=$(parse_item_val "${node_array_items[3]}" | cut -d' ' -f2)
          mem_lim_val=$(parse_item_val "${node_array_items[4]}"  | cut -d' ' -f1)
          mem_lim_unit=$(parse_item_val "${node_array_items[4]}" | cut -d' ' -f2)

          # Used resources %
          cpu_req_pct=$(parse_item_pct "${node_array_items[1]}")
          cpu_lim_pct=$(parse_item_pct "${node_array_items[2]}")
          mem_req_pct=$(parse_item_pct "${node_array_items[3]}")
          mem_lim_pct=$(parse_item_pct "${node_array_items[4]}")

          # Left resources %
          cpu_req_left_pct=$(echo "100 - ${cpu_req_pct}" | bc)
          cpu_lim_left_pct=$(echo "100 - ${cpu_lim_pct}" | bc)
          mem_req_left_pct=$(echo "100 - ${mem_req_pct}" | bc)
          mem_lim_left_pct=$(echo "100 - ${mem_lim_pct}" | bc)

          # Left resources values
          cpu_req_left_val=$(echo "(${cpu_req_left_pct} * ${cpu_req_val}) / ${cpu_req_pct}" | bc)
          cpu_lim_left_val=$(echo "(${cpu_lim_left_pct} * ${cpu_lim_val}) / ${cpu_lim_pct}" | bc)
          mem_req_left_val=$(echo "(${mem_req_left_pct} * ${mem_req_val}) / ${mem_req_pct}" | bc)
          mem_lim_left_val=$(echo "(${mem_lim_left_pct} * ${mem_lim_val}) / ${mem_lim_pct}" | bc)

          # node, cpu_req_val, cpu_req_pct, cpu_lim_val, cpu_lim_pct, cpu_lim_left_val, cpu_lim_left_pct, 
          #       mem_req_val, mem_req_pct, mem_lim_val, mem_lim_pct, mem_lim_left_val, mem_lim_left_pct
          node_all_items=(${node} "${cpu_req_val}${cpu_req_unit} (${cpu_req_pct}%)" 
                                  "${cpu_lim_val}${cpu_lim_unit} (${cpu_lim_pct}%)" 
                                  "${cpu_lim_left_val}${cpu_lim_unit} (${cpu_lim_left_pct}%)"
                                  "${mem_req_val}${mem_req_unit} (${mem_req_pct}%)" 
                                  "${mem_lim_val}${mem_lim_unit} (${mem_lim_pct}%)" 
                                  "${mem_lim_left_val}${mem_lim_unit} (${mem_lim_left_pct}%)"
                         )   
          # Total avg calcul
          TOTAL_REQ_CPU_PCT=$(echo "${TOTAL_REQ_CPU_PCT} + ${cpu_req_pct}" | bc)
          TOTAL_LIM_CPU_PCT=$(echo "${TOTAL_LIM_CPU_PCT} + ${cpu_lim_pct}" | bc)
          TOTAL_LIM_CPU_LEFT_PCT=$(echo "${TOTAL_LIM_CPU_LEFT_PCT} + ${cpu_lim_left_pct}" | bc)
          TOTAL_REQ_MEM_PCT=$(echo "${TOTAL_REQ_MEM_PCT} + ${mem_req_pct}" | bc)
          TOTAL_LIM_MEM_PCT=$(echo "${TOTAL_LIM_MEM_PCT} + ${mem_lim_pct}" | bc)
          TOTAL_LIM_MEM_LEFT_PCT=$(echo "${TOTAL_LIM_MEM_LEFT_PCT} + ${mem_lim_left_pct}" | bc)
        fi
        printf "${NODE_FMT}" ${node_all_items[@]} >> ${TEMP_LOG_FILE}
    done

    # ---------------------------
    # Display total resource usage 
    #
    TOTAL_REQ_CPU_PCT=$(expr ${TOTAL_REQ_CPU_PCT} / ${TOTAL_NODES})
    TOTAL_LIM_CPU_PCT=$(expr ${TOTAL_LIM_CPU_PCT} / ${TOTAL_NODES})
    TOTAL_LIM_CPU_LEFT_PCT=$(expr ${TOTAL_LIM_CPU_LEFT_PCT} / ${TOTAL_NODES})
    TOTAL_REQ_MEM_PCT=$(expr ${TOTAL_REQ_MEM_PCT} / ${TOTAL_NODES})
    TOTAL_LIM_MEM_PCT=$(expr ${TOTAL_LIM_MEM_PCT} / ${TOTAL_NODES})
    TOTAL_LIM_MEM_LEFT_PCT=$(expr ${TOTAL_LIM_MEM_LEFT_PCT} / ${TOTAL_NODES})
    printf "${NODE_FMT}" "---------------------------------------------" \
                         "----------" \
                         "----------" \
                         "----------" \
                         "----------" \
                         "----------" \
                         "----------" >> ${TEMP_LOG_FILE}
    printf "${NODE_FMT}" "Total ${TOTAL_NODES} nodes resources usage :"  \
                         "AVG: ${TOTAL_REQ_CPU_PCT}%" \
                         "AVG: ${TOTAL_LIM_CPU_PCT}%" \
                         "AVG: ${TOTAL_LIM_CPU_LEFT_PCT}%" \
                         "AVG: ${TOTAL_REQ_MEM_PCT}%" \
                         "AVG: ${TOTAL_LIM_MEM_PCT}%" \
                         "AVG: ${TOTAL_LIM_MEM_LEFT_PCT}%" >> ${TEMP_LOG_FILE}
    echo >> ${TEMP_LOG_FILE}
}

compute_pods_infos(){
    declare -A NS_POD
    declare -A NS_SVC

    # override conf with existing ns by default
    if [ -z "${CONF_NS}" ]; then
        MONITORED_NS=($(${KUBECTL} get namespaces | awk 'NR>1 {print $1}'))
    fi

    # get namespaces pod/services
    for ns in ${MONITORED_NS[@]}; do
        NS_POD[${ns}]=$(get_pods ${ns})
        NS_SVC[${ns}]=$(get_services ${ns})
    done
    
    POD_FMT="%-55s%-10s%-20s%-8s%-8s\n"
    for ns in ${MONITORED_NS[@]}; do
        test -n "${NS_POD[${ns}]}" && NS_POD_CNT=$(echo "${NS_POD[${ns}]}" | wc -l) || NS_POD_CNT=0
        test -n "${NS_SVC[${ns}]}" && NS_SVC_CNT=$(echo "${NS_SVC[${ns}]}" | wc -l) || NS_SVC_CNT=0
        
        NS_UPPER=$(echo ${ns} | tr '[:lower:]' '[:upper:]')
        sep_big=$(printf '=%.0s' {1..100})
        sep_low=$(printf -- '-%.0s' {1..100})

        printf "${POD_FMT}" "${sep_big}" >> ${TEMP_LOG_FILE}
        printf "${bold}${POD_FMT}${end}" "${NS_UPPER} pods: ${NS_POD_CNT}" \
                                         "${NS_UPPER} services: ${NS_SVC_CNT}" >> ${TEMP_LOG_FILE}
        printf "${POD_FMT}" "${sep_low}" >> ${TEMP_LOG_FILE}
       
        if [ ${NS_POD_CNT} -ge 1 ]; then
          printf "${POD_FMT}" "Pod Name" \
                              "Ready" \
                              "Status" \
                              "Restart" \
                              "Lifetime" >> ${TEMP_LOG_FILE}
          printf "${POD_FMT}" "---------------------------------------------" \
                              "-----" \
                              "------" \
                              "-------" \
                              "-------" >> ${TEMP_LOG_FILE}
          
          for line in ${NS_POD[${ns}]}; do
            declare -a line_items=$(echo "$line" | perl -npe 's/\s+$//' | perl -npe 's/(\s{1,}|\t)/\n/g')

            if [[ "${line_items[0]}" =~ Running|Succeeded ]]; then
                printf "${POD_FMT}" ${line_items[@]} >> ${TEMP_LOG_FILE}

            elif [[ "${line_items[0]}" =~ Completed ]]; then
                printf "${bold}${POD_FMT}${end}" ${line_items[@]} >> ${TEMP_LOG_FILE}
            
            elif [[ "${line_items[0]}" =~ ContainerCreating|Init ]]; then
                printf "${yel}${POD_FMT}${end}" ${line_items[@]} >> ${TEMP_LOG_FILE}

            elif [[ "${line_items[0]}" =~ Pending|Unknown ]]; then
                printf "${yelbold}${POD_FMT}${end}" ${line_items[@]} >> ${TEMP_LOG_FILE}

            elif [[ "${line_items[0]}" =~ Terminating ]]; then
                printf "${red}${POD_FMT}${end}" ${line_items[@]} >> ${TEMP_LOG_FILE} 

            elif [[ "${line_items[0]}" =~ Failed|ImagePullBackOff|CrashLoopBackOff ]]; then
                printf "${redbold}${POD_FMT}${end}" ${line_items[@]} >> ${TEMP_LOG_FILE}

            # title repeat when list too long
            elif [[ "${line_items[0]}" =~ NAME|READY|STATUS|RESTARTS|AGE ]]; then
                printf "${bold}${POD_FMT}${end}" ${line_items[@]} >> ${TEMP_LOG_FILE}
            
            else
                printf "${redbold}${POD_FMT}${end}" ${line_items[@]} >> ${TEMP_LOG_FILE}
            fi
          done
        fi
        echo "" >> ${TEMP_LOG_FILE}
    done
}



print_help() {
    cat <<EOTXT
Usage: $(basename $0) [options...]

No option will whatch for nodes and pod resources on all available namespaces

  -w    Filter Pods from configurated namespaces only
  -c    Display Clusters deployed resources and exit
  -n    Display Nodes used resources informations and exit
  -p    Watch only Pods deployed resources informations
  -h    Display this help

  To define pods namespaces filtering with "-w",
  edit the MONITORED_NS array in script.

EOTXT
    exit
}


#
# Main
#
trap cleanup INT TERM

# poor args parsing
while (( "$#" )); do
   case $1 in
      -w) CONF_NS="true" ;;
      -c) CLUSTER_ONLY="true" ;;
      -n) NODES_ONLY="true" ;;
      -p) PODS_ONLY="true" ;;
      -h) print_help ;;
   esac
   shift
done

check_k8s_connexion;

echo "Please wait for cluster informations gathering..."

# get default IFS
IFS_DEFAULT=$IFS

# main loop
while :; do
  NODES_ITEMS_LIST=""

  IFS=${IFS_DEFAULT}

  # collect nodes infos
  if [[ -z "${PODS_ONLY}" && -z "${CLUSTER_ONLY}" ]]; then
    get_nodes_infos;
  fi

  # refresh only pods data in loop
  for i in {1..10}; do
      
      # prepare file results
      > ${TEMP_LOG_FILE}
      printf "\n" >> ${TEMP_LOG_FILE}

      IFS=$'\n'

      # ---------------------------
      # Compute/Write Cluster informations
      #
      if [ -n "${CLUSTER_ONLY}" ]; then
        compute_cluster_resources;
        clear_screen
        cat ${TEMP_LOG_FILE}
        exit
      fi        

      # ---------------------------
      # Compute/Write Nodes informations
      #
      if [[ -z "${PODS_ONLY}" && -z "${CLUSTER_ONLY}" ]]; then
        compute_nodes_infos;
      fi

      # exit if node only enabled
      if [ -n "${NODES_ONLY}" ]; then
        clear_screen
        cat ${TEMP_LOG_FILE}
        exit
      fi

      # ---------------------------
      # Compute/Write Pods informations
      #
      if [ -z "${NODES_ONLY}" ]; then
        compute_pods_infos;
      fi
      
      clear_screen
      cat ${TEMP_LOG_FILE}

      # refresh period
      sleep ${REFRESH_TIME}

  done
done

