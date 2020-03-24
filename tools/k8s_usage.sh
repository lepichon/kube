#!/bin/bash

# requierd kubectl >= 1.11
# need pods metrics to be enabled on cluster for the pods consumptions (kubectl top)
# need os supporting newline as \n

# TODO : handle total_node = 0 (divided by zero not possible)

declare -a MONITORED_NS
declare -A NODES_CONSUMPTION

# Refresh time after informations are collected
REFRESH_TIME=4

# kube cli
KUBECTL="kubectl"

TEMP_LOG_FILE="/tmp/$(basename $0).$RANDOM"

# term colors
bold=$'\e[1m'
red=$'\e[31m'
yel=$'\e[33m'
redbold=$'\e[1;31m'
yelbold=$'\e[1;33m'
end=$'\e[0m'

tabs -18
export LC_ALL=C

declare -a MONITORED_NS
declare -A NODES_CONSUMPTION

NODE_FMT=""
NO_METRICS_LABEL="no-metrics"

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
    ns=$1
    ${KUBECTL} get services -n $ns 2>/dev/null \
        | awk 'NR>1 {printf "%-50s %-4s %-10s %s\n", $1, $2, $3, $4}'
}

get_pods() {
    ns=$1
    ${KUBECTL} get pods -n $ns 2>/dev/null \
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
    echo "Please wait for cluster informations gathering..."
}

# return val% from "654m (21%)"
parse_item_desc_pct() {
    val=$1
    echo "$val" | sed 's/.*(\([0-9]\+\)\%).*/\1/'
}

# return val% "21%"
parse_item_top_pct() {
    val=$1
    echo "$val" | sed 's/\([0-9]\+\)\%/\1/'
}

# return value from valueunit
parse_item_val() {
    val=$1
    echo "$val" | perl -npe 's/([0-9]+)([gmki]{1,2})?\s.*/$1/i'
}

# return unit from valueunit
parse_item_unit() {
    val=$1
    echo "$val" | perl -npe 's/([0-9]+)([gmki]{1,2})?\s.*/$2/i'
}

clear_screen() {
    #clear && echo -en "\e[3J"
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
    done < <(${KUBECTL} get pvc --all-namespaces \
               -o jsonpath='{.items[?(@.kind=="PersistentVolumeClaim")].status.capacity.storage}' \
               | tr ' ' '\n' && echo)
                            
    # nodes RAM
    while read s; do
        bytesize=$(sizehumanToBytes "$s")
        total_nodes_mem=$((( ${total_nodes_mem} + ${bytesize} )))
        (( total_nodes_cnt++ ))
    done < <(${KUBECTL} get nodes \
                -o jsonpath='{.items[?(@.kind=="Node")].status.capacity.memory}' \
                | tr ' ' '\n' && echo)
    
    # nodes vCPU
    total_nodes_cpu=$(${KUBECTL} get nodes \
                        -o jsonpath='{.items[?(@.kind=="Node")].status.capacity.cpu}' \
                        | tr ' ' '\n' \
                        | awk '{sum+=$1} END { print sum}')
    
    # nodes flavor
    while read flavor; do
        nodes_flavors[$flavor]=$((( nodes_flavors[$flavor]+1 )))
    done < <(${KUBECTL} get nodes -o=yaml \
                | grep beta.kubernetes.io/instance-type: \
                | awk '{print $2}')

    # init output file
    > ${TEMP_LOG_FILE}

    CLUSTER_FMT="%-25s%-15s\n"
    FLAVOR_FMT="%25s%-15s\n"

    # Display results
    printf "${CLUSTER_FMT}" "=======================" "==================" >> ${TEMP_LOG_FILE}
    printf "${CLUSTER_FMT}" "Nodes count:" "${total_nodes_cnt}" >> ${TEMP_LOG_FILE}
    printf "${CLUSTER_FMT}" "-----------------------" "------------------" >> ${TEMP_LOG_FILE}
    printf "${CLUSTER_FMT}" "Total Nodes Memory:" "$(sizeBytesToHuman ${total_nodes_mem}) (${total_nodes_mem} bytes)"  >> ${TEMP_LOG_FILE}
    printf "${CLUSTER_FMT}" "-----------------------" "------------------" >> ${TEMP_LOG_FILE}
    printf "${CLUSTER_FMT}" "Total Nodes vCPUs:" "${total_nodes_cpu}" >> ${TEMP_LOG_FILE}
    printf "${CLUSTER_FMT}" "-----------------------" "------------------" >> ${TEMP_LOG_FILE}
    printf "${CLUSTER_FMT}" "Total Physical volumes:" "$(sizeBytesToHuman ${total_size_pvc}) (${total_size_pvc} bytes)" >> ${TEMP_LOG_FILE}
    printf "${CLUSTER_FMT}" "-----------------------" "------------------" >> ${TEMP_LOG_FILE}
    printf "${CLUSTER_FMT}" "Nodes flavors:" "" >> ${TEMP_LOG_FILE}
    for i in ${!nodes_flavors[@]}; do
        printf "${FLAVOR_FMT}" "${nodes_flavors[$i]} x  " "$i" >> ${TEMP_LOG_FILE}
    done
    printf "${CLUSTER_FMT}" "-----------------------" "------------------" >> ${TEMP_LOG_FILE}
}

# compute node kubectl describe infos
compute_nodes_desc_infos() {
  NODES_ITEMS_STR=""

  IFS="$IFS_DEFAULT"
  KUBE_NODES=($(${KUBECTL} get nodes -o jsonpath='{.items[*].metadata.name}'))

  # init output file
  > ${TEMP_LOG_FILE}

  NODE_FMT="%-55s%-15s%-15s%-20s%-20s%-20s%-20s\n"
 
  # Nodes columns format
  printf "${NODE_FMT}" "=============================================" \
                       "==========" "==========" "==============" \
                       "==========" "==========" "==============" >> ${TEMP_LOG_FILE}
  printf "${bold}${NODE_FMT}${end}" "NODES Hostname" \
                                    "CPU Req" "CPU Limit" "CPU Limit Free" \
                                    "Mem Request" "Mem Limit" "Mem Limit Free" >> ${TEMP_LOG_FILE}
  printf "${NODE_FMT}" "---------------------------------------------" \
                       "----------" "----------" "-------------" \
                       "----------" "----------" "-------------" >> ${TEMP_LOG_FILE}
  IFS=$'\n'
  declare -a nodes_line_items
  
  for node in ${KUBE_NODES[@]}; do 
      nodes_line_items=($(${KUBECTL} describe node ${node} \
                                | grep -A5 "Allocated" \
                                | egrep '\s*(cpu|memory)' \
                                | perl -npe 's/\s+(?:cpu|memory)\s+(.*)\n/$1 /' \
                                | perl -npe 's/((?:[^\s]+\s+){4})((?:[^\s]+\s+){4})/$1\t$2\n/g'))
      NODES_CONSUMPTION["${node}"]="${nodes_line_items[@]}"
  done
}

# compute node kubect top infos
compute_nodes_top_infos() {
   # get nodes consumed resources for current ns
   declare -a nodes_line_items

   # init output file
   > ${TEMP_LOG_FILE}

   NODE_FMT="%-55s%-15s%-15s%-15s%-20s%-20s%-20s\n"

   # Nodes columns format
   printf "${NODE_FMT}" "=============================================" \
                        "==========" "==========" "==========" \
                        "==========" "==========" "==========" >> ${TEMP_LOG_FILE}
   printf "${bold}${NODE_FMT}${end}" "NODES Hostname" \
                                     "CPU Usage" "CPU Usage %" "CPU Free" \
                                     "Mem Usage" "Mem Usage %" "Mem Free" >> ${TEMP_LOG_FILE}
   printf "${NODE_FMT}" "---------------------------------------------" \
                        "----------" "----------" "----------" \
                        "----------" "----------" "----------" >> ${TEMP_LOG_FILE}
   
   for node_line in $(${KUBECTL} top nodes --no-headers 2>/dev/null); do
       nodes_line_items=($(echo "$node_line" | perl -npe 's/\s+$//' | perl -npe 's/(\s{1,}|\t)/\n/g'))
       NODES_CONSUMPTION["${nodes_line_items[0]}"]="${nodes_line_items[@]:1}"
   done

   # verify consumption data on existing nodes
   IFS=$IFS_DEFAULT
   declare -a node_list
   for node in $(${KUBECTL} get nodes --no-headers -o=jsonpath='{.items[*].metadata.name}'); do
     if [ "${NODES_CONSUMPTION[$node]}" == ""  ]; then
        NODES_CONSUMPTION["$node"]="${NO_METRICS_LABEL}"
     fi
   done
   IFS=$'\n'
}

display_nodes_infos() {
    # ---------------------------
    # Display Nodes informations
    #
  
    let TOTAL_NODES=0
    let TOTAL_REQ_CPU_PCT=TOTAL_LIM_CPU_PCT=TOTAL_LIM_CPU_FREE_PCT=0
    let TOTAL_REQ_MEM_PCT=TOTAL_LIM_MEM_PCT=TOTAL_LIM_MEM_FREE_PCT=0
    let TOTAL_CPU_VAL=TOTAL_CPU_PCT=TOTAL_CPU_FREE_PCT=TOTAL_MEM_VAL=TOTAL_MEM_PCT=TOTAL_MEM_FREE_PCT=0

    for node in ${!NODES_CONSUMPTION[@]}; do
        # split node line items columns
        node_array_items=($(echo "${NODES_CONSUMPTION[$node]}" \
                                | perl -npe 's/\s+$//' \
                                | perl -npe 's/(\s{2,}|\t)/\n/g'))
        
        declare -a node_all_items=()
        # calcul total resources usage percentage (excluding master)
        if ! [[ "${node}" =~ master ]]; then
          TOTAL_NODES=$(expr ${TOTAL_NODES} + 1)

          # display node workload resources requests/limits
          if [ -n "${NODES_WORKLOAD}" ]; then
            # Used resources values
            cpu_req_val=$(parse_item_val "${node_array_items[0]}")
            cpu_req_unit=$(parse_item_unit "${node_array_items[0]}")
            cpu_lim_val=$(parse_item_val "${node_array_items[1]}")
            cpu_lim_unit=$(parse_item_unit "${node_array_items[1]}")
            mem_req_val=$(parse_item_val "${node_array_items[2]}")
            mem_req_unit=$(parse_item_unit "${node_array_items[2]}")
            mem_lim_val=$(parse_item_val "${node_array_items[3]}")
            mem_lim_unit=$(parse_item_unit "${node_array_items[3]}")

            # Used resources %
            cpu_req_pct=$(parse_item_desc_pct "${node_array_items[0]}")
            cpu_lim_pct=$(parse_item_desc_pct "${node_array_items[1]}")
            mem_req_pct=$(parse_item_desc_pct "${node_array_items[2]}")
            mem_lim_pct=$(parse_item_desc_pct "${node_array_items[3]}")

            # Free resources %
            cpu_req_free_pct=$(echo "100 - ${cpu_req_pct}" | bc)
            cpu_lim_free_pct=$(echo "100 - ${cpu_lim_pct}" | bc)
            mem_req_free_pct=$(echo "100 - ${mem_req_pct}" | bc)
            mem_lim_free_pct=$(echo "100 - ${mem_lim_pct}" | bc)

            ## Free resources values
            let cpu_req_free_val=cpu_lim_free_val=mem_req_free_val=mem_lim_free_val=0

            [[ ${cpu_req_pct} -ne 0 ]] && cpu_req_free_val=$(echo "(${cpu_req_free_pct} * ${cpu_req_val}) / ${cpu_req_pct}" | bc)
            [[ ${cpu_lim_pct} -ne 0 ]] && cpu_lim_free_val=$(echo "(${cpu_lim_free_pct} * ${cpu_lim_val}) / ${cpu_lim_pct}" | bc)
            [[ ${mem_req_pct} -ne 0 ]] && mem_req_free_val=$(echo "(${mem_req_free_pct} * ${mem_req_val}) / ${mem_req_pct}" | bc)
            [[ ${mem_lim_pct} -ne 0 ]] && mem_lim_free_val=$(echo "(${mem_lim_free_pct} * ${mem_lim_val}) / ${mem_lim_pct}" | bc)
            
            node_all_items=("${node}" "${cpu_req_val}${cpu_req_unit} (${cpu_req_pct}%)" 
                                      "${cpu_lim_val}${cpu_lim_unit} (${cpu_lim_pct}%)" 
                                      "${cpu_lim_free_val}${cpu_lim_unit} (${cpu_lim_free_pct}%)"
                                      "${mem_req_val}${mem_req_unit} (${mem_req_pct}%)" 
                                      "${mem_lim_val}${mem_lim_unit} (${mem_lim_pct}%)" 
                                      "${mem_lim_free_val}${mem_lim_unit} (${mem_lim_free_pct}%)"
                           )   
            # Total avg calcul
            TOTAL_REQ_CPU_PCT=$(echo "${TOTAL_REQ_CPU_PCT} + ${cpu_req_pct}" | bc)
            TOTAL_LIM_CPU_PCT=$(echo "${TOTAL_LIM_CPU_PCT} + ${cpu_lim_pct}" | bc)
            TOTAL_LIM_CPU_FREE_PCT=$(echo "${TOTAL_LIM_CPU_FREE_PCT} + ${cpu_lim_free_pct}" | bc)
            TOTAL_REQ_MEM_PCT=$(echo "${TOTAL_REQ_MEM_PCT} + ${mem_req_pct}" | bc)
            TOTAL_LIM_MEM_PCT=$(echo "${TOTAL_LIM_MEM_PCT} + ${mem_lim_pct}" | bc)
            TOTAL_LIM_MEM_FREE_PCT=$(echo "${TOTAL_LIM_MEM_FREE_PCT} + ${mem_lim_free_pct}" | bc)
 
          # display node real usage
          elif [ -n "${NODES_USAGE}" ]; then

            if [ "${node_array_items[0]}" == "${NO_METRICS_LABEL}" ]; then
                node_all_items=(${node} "${NO_METRICS_LABEL}" "${NO_METRICS_LABEL}" "${NO_METRICS_LABEL}"  
                                        "${NO_METRICS_LABEL}" "${NO_METRICS_LABEL}" "${NO_METRICS_LABEL}")
                cpu_val="" cpu_unit="" cpu_pct=""
                mem_val="" mem_unt=""  mem_pct=""

            else
                # Used resources
                cpu_val=$(parse_item_val "${node_array_items[0]}")
                cpu_unit=$(parse_item_unit "${node_array_items[0]}")
                cpu_pct=$(parse_item_top_pct "${node_array_items[1]}")
                mem_val=$(parse_item_val "${node_array_items[2]}")
                mem_unit=$(parse_item_unit "${node_array_items[2]}")
                mem_pct=$(parse_item_top_pct "${node_array_items[3]}")

                # Free resources
                cpu_free_pct=$(echo "100 - ${cpu_pct}" | bc)
                mem_free_pct=$(echo "100 - ${mem_pct}" | bc)

                let cpu_free_val=mem_free_val=0

                [[ ${cpu_pct} -ne 0 ]] && cpu_free_val=$(echo "(${cpu_free_pct} * ${cpu_val}) / ${cpu_pct}" | bc)
                [[ ${mem_pct} -ne 0 ]] && mem_free_val=$(echo "(${mem_free_pct} * ${mem_val}) / ${mem_pct}" | bc)

                node_all_items=(${node} "${node_array_items[0]}" "${node_array_items[1]}" 
                                        "${cpu_free_val}${cpu_unit} (${cpu_free_pct}%)"
                                        "${node_array_items[2]}" "${node_array_items[3]}" 
                                        "${mem_free_val}${mem_unit} (${mem_free_pct}%)" )
                # Total avg calcul
                TOTAL_CPU_VAL=$(echo "${TOTAL_CPU_VAL} + ${cpu_val}" | bc)
                TOTAL_CPU_PCT=$(echo "${TOTAL_CPU_PCT} + ${cpu_pct}" | bc)
                TOTAL_CPU_FREE_PCT=$(echo "${TOTAL_CPU_FREE_PCT} + ${cpu_free_pct}" | bc)
                TOTAL_MEM_VAL=$(echo "${TOTAL_MEM_VAL} + ${mem_val}" | bc)
                TOTAL_MEM_PCT=$(echo "${TOTAL_MEM_PCT} + ${mem_pct}" | bc)
                TOTAL_MEM_FREE_PCT=$(echo "${TOTAL_MEM_FREE_PCT} + ${mem_free_pct}" | bc)                            
            fi
          fi
        fi
        printf "${NODE_FMT}" ${node_all_items[@]} >> ${TEMP_LOG_FILE}
    done

    # ---------------------------
    # Display total resource usage 
    #
    if [ -n "${NODES_WORKLOAD}" ]; then
        TOTAL_REQ_CPU_PCT=$(expr ${TOTAL_REQ_CPU_PCT} / ${TOTAL_NODES})
        TOTAL_LIM_CPU_PCT=$(expr ${TOTAL_LIM_CPU_PCT} / ${TOTAL_NODES})
        TOTAL_LIM_CPU_FREE_PCT=$(expr ${TOTAL_LIM_CPU_FREE_PCT} / ${TOTAL_NODES})
        TOTAL_REQ_MEM_PCT=$(expr ${TOTAL_REQ_MEM_PCT} / ${TOTAL_NODES})
        TOTAL_LIM_MEM_PCT=$(expr ${TOTAL_LIM_MEM_PCT} / ${TOTAL_NODES})
        TOTAL_LIM_MEM_FREE_PCT=$(expr ${TOTAL_LIM_MEM_FREE_PCT} / ${TOTAL_NODES})
        printf "${NODE_FMT}" "---------------------------------------------" \
                             "----------" "----------" "----------" \
                             "----------" "----------" "----------" >> ${TEMP_LOG_FILE}
        printf "${NODE_FMT}" "Total ${TOTAL_NODES} nodes resources usage :"  \
                             "AVG: ${TOTAL_REQ_CPU_PCT}%" \
                             "AVG: ${TOTAL_LIM_CPU_PCT}%" \
                             "AVG: ${TOTAL_LIM_CPU_FREE_PCT}%" \
                             "AVG: ${TOTAL_REQ_MEM_PCT}%" \
                             "AVG: ${TOTAL_LIM_MEM_PCT}%" \
                             "AVG: ${TOTAL_LIM_MEM_FREE_PCT}%" >> ${TEMP_LOG_FILE}

    elif [ -n "${NODES_USAGE}" ]; then
        TOTAL_CPU_VAL=$(expr ${TOTAL_CPU_VAL} / ${TOTAL_NODES})
        TOTAL_CPU_PCT=$(expr ${TOTAL_CPU_PCT} / ${TOTAL_NODES})
        TOTAL_CPU_FREE_PCT=$(expr ${TOTAL_CPU_FREE_PCT} / ${TOTAL_NODES})
        TOTAL_MEM_VAL=$(expr ${TOTAL_MEM_VAL} / ${TOTAL_NODES})
        TOTAL_MEM_PCT=$(expr ${TOTAL_MEM_PCT} / ${TOTAL_NODES})
        TOTAL_MEM_FREE_PCT=$(expr ${TOTAL_MEM_FREE_PCT} / ${TOTAL_NODES})

        printf "${NODE_FMT}" "---------------------------------------------" \
                             "----------" "----------" "----------" \
                             "----------" "----------" "----------" >> ${TEMP_LOG_FILE}
        printf "${NODE_FMT}" "Total ${TOTAL_NODES} nodes resources usage :"  \
                             "AVG: ${TOTAL_CPU_VAL}${cpu_unit}" \
                             "AVG: ${TOTAL_CPU_PCT}%" \
                             "AVG: ${TOTAL_CPU_FREE_PCT}%" \
                             "AVG: ${TOTAL_MEM_VAL}${mem_unit}" \
                             "AVG: ${TOTAL_MEM_PCT}%" \
                             "AVG: ${TOTAL_MEM_FREE_PCT}%" >> ${TEMP_LOG_FILE}
    fi

    echo >> ${TEMP_LOG_FILE}
}

compute_pods_infos(){
    declare -A NS_POD
    declare -A NS_SVC

    # init output file
    > ${TEMP_LOG_FILE}

    # override conf with existing ns by default
    if [ -z "${CONF_NS}" ]; then
        MONITORED_NS=($(${KUBECTL} get namespaces | awk 'NR>1 {print $1}'))
    else
        MONITORED_NS=($(echo "${NS_FILTER}" | perl -npe 's/[,\s]/\n/g'))
    fi
    POD_FMT="%-55s%-10s%-20s%-15s%-15s%-8s%-8s\n"
    for ns in ${MONITORED_NS[@]}; do

        # get namespaces pod/services
        NS_POD[${ns}]=$(get_pods ${ns})
        NS_SVC[${ns}]=$(get_services ${ns})
        
        test -n "${NS_POD[${ns}]}" && NS_POD_CNT=$(echo "${NS_POD[${ns}]}" | wc -l) || NS_POD_CNT=0
        test -n "${NS_SVC[${ns}]}" && NS_SVC_CNT=$(echo "${NS_SVC[${ns}]}" | wc -l) || NS_SVC_CNT=0
 
        # get pods consumed resources for current ns
        declare -A PODS_CONSUMPTION
        declare -a pods_line_items
        for pod_line in $(${KUBECTL} top pods -n ${ns} --no-headers 2>/dev/null); do
            pods_line_items=($(echo "$pod_line" | perl -npe 's/\s+$//' | perl -npe 's/(\s{1,}|\t)/\n/g'))
            PODS_CONSUMPTION[${pods_line_items[0]}]=${pods_line_items[@]:1}
        done

        NS_UPPER=$(echo ${ns} | tr '[:lower:]' '[:upper:]')
        sep_big=$(printf '=%.0s' {1..130})
        sep_low=$(printf -- '-%.0s' {1..130})

        printf "${POD_FMT}" "${sep_big}" >> ${TEMP_LOG_FILE}
        printf "${bold}${POD_FMT}${end}" "${NS_UPPER} pods: ${NS_POD_CNT}" \
                                         "${NS_UPPER} services: ${NS_SVC_CNT}" >> ${TEMP_LOG_FILE}
        printf "${POD_FMT}" "${sep_low}" >> ${TEMP_LOG_FILE}
       
        if [ ${NS_POD_CNT} -ge 1 ]; then
          printf "${POD_FMT}" "Pod Name" \
                              "Ready" "Status" "Restart" \
                              "Lifetime" "CPUs" "Memory" >> ${TEMP_LOG_FILE}
          printf "${POD_FMT}" "---------------------------------------------" \
                              "-----" "------" "-------" \
                              "-------" "-------" "-------" >> ${TEMP_LOG_FILE}
           
          for line in ${NS_POD[${ns}]}; do
            declare -a line_items=($(echo "$line" \
                                        | perl -npe 's/\s+$//' \
                                        | perl -npe 's/(\s{1,}|\t)/\n/g'))
            
            # add resource consumption infos
            line_items+=($(echo "${PODS_CONSUMPTION[${line_items[0]}]}" \
                                | perl -npe 's/\s+$//' \
                                | perl -npe 's/(\s{1,}|\t)/\n/g'))

            if [[ "${line_items[2]}" =~ Running|Succeeded ]]; then
                printf "${POD_FMT}" ${line_items[@]} >> ${TEMP_LOG_FILE}

            elif [[ "${line_items[2]}" =~ Completed ]]; then
                printf "${bold}${POD_FMT}${end}" ${line_items[@]} >> ${TEMP_LOG_FILE}
            
            elif [[ "${line_items[2]}" =~ ContainerCreating|Init ]]; then
                printf "${yel}${POD_FMT}${end}" ${line_items[@]} >> ${TEMP_LOG_FILE}

            elif [[ "${line_items[2]}" =~ Pending|Unknown ]]; then
                printf "${yelbold}${POD_FMT}${end}" ${line_items[@]} >> ${TEMP_LOG_FILE}

            elif [[ "${line_items[2]}" =~ Terminating ]]; then
                printf "${red}${POD_FMT}${end}" ${line_items[@]} >> ${TEMP_LOG_FILE} 

            elif [[ "${line_items[2]}" =~ Failed|ImagePullBackOff|CrashLoopBackOff ]]; then
                printf "${redbold}${POD_FMT}${end}" ${line_items[@]} >> ${TEMP_LOG_FILE}

            # title repeat when list too long
            elif [[ "${line_items[2]}" =~ NAME|READY|STATUS|RESTARTS|AGE ]]; then
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

No option, will watch for pod resources on all available namespaces

  -c | --cluster                Display Cluster total deployed resources and exit
  -w | --nodes-workload         Display Nodes usage on workload configured req. and lim. and exit
  -u | --node-usage             Display Nodes real workload usage informations and exit
  -p | --pods                   Watch for deployed Pods resources and consumption informations
  -n | --namespace ns1,ns2,...  Filter Pods list on provided namespaces, list with separator "," or space quoted)
  -h | --help                   Display this help

EOTXT
    exit
}


#
# Main
#
trap cleanup INT TERM EXIT

# Parse options
#
GETOPT_TEMP=$(getopt -o hcuwpn: --long \
              help,cluster,nodes-usage,nodes-workload,pods,namespaces: -n "$(basename $0)" -- "$@")
if [ $? != 0 ] ; then 
	echo
    print_help
fi

eval set -- "$GETOPT_TEMP"
while true ; do
    case "$1" in
        -h | --help)                                            print_help ;;
        -c | --cluster)         CLUSTER_ONLY="true";            shift ;;
        -u | --nodes-usage)     NODES_USAGE="true";             shift ;;
        -w | --nodes-workload)  NODES_WORKLOAD="true";          shift ;;
        -p | --pods)            PODS_USAGE="true";              shift ;;
        -n | --namespaces)      CONF_NS="true"; NS_FILTER="$2"; shift 2 ;;
        --)                     shift;                          break ;;
    esac
done

# handle no options
if [ "$#" -eq 0 ]; then
    PODS_USAGE="true"
fi


# check cluster existing session
check_k8s_connexion;

# get default IFS
IFS_DEFAULT=$IFS

# set IFS on new line 
# for general string 2 array conversions
IFS=$'\n'

# ---------------------------
# Cluster informations
#
if [ -n "${CLUSTER_ONLY}" ]; then
    compute_cluster_resources;
    clear_screen
    cat ${TEMP_LOG_FILE}
    exit
fi

# ---------------------------
# Nodes informations
#
if [[ -n "${NODES_USAGE}" || -n "${NODES_WORKLOAD}" ]]; then
    if [ -n "${NODES_USAGE}" ]; then
        compute_nodes_top_infos;
    elif [ -n "${NODES_WORKLOAD}" ]; then
        compute_nodes_desc_infos;
    fi
    display_nodes_infos;
    clear_screen
    cat ${TEMP_LOG_FILE}
    exit;
fi

# ---------------------------
# Pods informations
#
while :; do
    printf "\n" >> ${TEMP_LOG_FILE}

    # ---------------------------
    # Compute/Write Pods informations
    #
    if [ -z "${NODES_ONLY}" ]; then
      compute_pods_infos;
    fi
    echo -e "\n\n!! Press [Enter] to follow refresh !!\n\n"
    clear_screen
    cat ${TEMP_LOG_FILE}

    # wait for new infos gathering/processing loop
    sleep ${REFRESH_TIME}
done

