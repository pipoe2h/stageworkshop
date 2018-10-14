#!/usr/bin/env bash

function NTNX_Download
{
  local   _checksum
  local   _meta_url='http://download.nutanix.com/'
  local _source_url
  local    _version=0

  if [[ ${1} == 'PC' ]]; then
    CheckArgsExist 'PC_VERSION'

    # When adding a new PC version, update BOTH case stanzas below...
    case ${PC_VERSION} in
      5.9 | 5.6.2 | 5.8.0.1 )
        _version=2
        ;;
      * )
        _version=1
        ;;
    esac

    _meta_url+="pc/one-click-pc-deployment/${PC_VERSION}/v${_version}/"
    case ${PC_VERSION} in
      5.9 )
        _meta_url+="euphrates-${PC_VERSION}-stable-prism_central_one_click_deployment_metadata.json"
        ;;
      5.6.1 | 5.6.2 )
        _meta_url+="euphrates-${PC_VERSION}-stable-prism_central_metadata.json"
        ;;
      5.7.0.1 | 5.7.1 | 5.7.1.1 )
        _meta_url+="pc-${PC_VERSION}-stable-prism_central_metadata.json"
        ;;
      5.8.0.1 | 5.8.1 | 5.8.2 | 5.10 | 5.11 )
        _meta_url+="pc_deploy-${PC_VERSION}.json"
        ;;
      * )
        _error=22
        log "Error ${_error}: unsupported PC_VERSION=${PC_VERSION}!"
        log 'Browse to https://portal.nutanix.com/#/page/releases/prismDetails'
        log " - Find ${PC_VERSION} in the Additional Releases section on the lower right side"
        log ' - Provide the metadata URL for the "PC 1-click deploy from PE" option to this function, both case stanzas.'
        exit ${_error}
        ;;
    esac
  else
    CheckArgsExist 'AOS_VERSION AOS_UPGRADE'

    # When adding a new AOS version, update BOTH case stanzas below...
    case ${AOS_UPGRADE} in
      5.8.0.1 )
        _version=2
        ;;
    esac

    _meta_url+="/releases/euphrates-${AOS_UPGRADE}-metadata/"

    if (( $_version > 0 )); then
      _meta_url+="v${_version}/"
    fi

    case ${AOS_UPGRADE} in
      5.8.0.1 | 5.9 )
        _meta_url+="euphrates-${AOS_UPGRADE}-metadata.json"
        ;;
      * )
        _error=23
        log "Error ${_error}: unsupported AOS_UPGRADE=${AOS_UPGRADE}!"
        # TODO: correct AOS_UPGRADE URL
        log 'Browse to https://portal.nutanix.com/#/page/releases/nosDetails'
        log " - Find ${AOS_UPGRADE} in the Additional Releases section on the lower right side"
        log ' - Provide the Upgrade metadata URL to this function for both case stanzas.'
        exit ${_error}
        ;;
    esac
  fi

  if [[ ! -e ${_meta_url##*/} ]]; then
    log "Retrieving download metadata ${_meta_url##*/} ..."
    Download "${_meta_url}"
  else
    log "Warning: using cached download ${_meta_url##*/}"
  fi

  _source_url=$(cat ${_meta_url##*/} | jq -r .download_url_cdn)

  if (( `pgrep curl | wc --lines | tr -d '[:space:]'` > 0 )); then
    pkill curl
  fi
  log "Retrieving Nutanix ${1} bits..."
  Download "${_source_url}"

  _checksum=$(md5sum ${_source_url##*/} | awk '{print $1}')
  if [[ `cat ${_meta_url##*/} | jq -r .hex_md5` != "${_checksum}" ]]; then
    log "Error: md5sum ${_checksum} doesn't match on: ${_source_url##*/} removing and exit!"
    rm -f ${_source_url##*/}
    exit 2
  else
    log "Success: ${1} bits downloaded and passed MD5 checksum!"
  fi

  # Set globals for next step handoff
  export   NTNX_META_URL=${_meta_url}
  export NTNX_SOURCE_URL=${_source_url}
}

function log {
  local _caller

  _caller=$(echo -n "`caller 0 | awk '{print $2}'`")
  echo "`date '+%Y-%m-%d %H:%M:%S'`|$$|${_caller}|${1}"
}

function TryURLs {
  #TODO: trouble passing an array to this function
  HTTP_CODE=$(curl ${CURL_OPTS} --write-out '%{http_code}' --head ${1} | tail -n1)
  export HTTP_CODE
}

function CheckArgsExist {
  local _argument
  local    _error=88

  for _argument in ${1}; do
    if [[ ${DEBUG} ]]; then
      log "DEBUG: Checking ${_argument}..."
    fi
    _RESULT=$(eval "echo \$${_argument}")
    if [[ -z ${_RESULT} ]]; then
      log "Error ${_error}: ${_argument} not provided!"
      exit ${_error}
    elif [[ ${DEBUG} ]]; then
      log "Non-error: ${_argument} for ${_RESULT}"
    fi
  done

  if [[ ${DEBUG} ]]; then
    log 'Success: required arguments provided.'
  fi
}

function SSH_PubKey {
  local   _NAME=${MY_EMAIL//\./_DOT_}
  local _SSHKEY=${HOME}/id_rsa.pub
  _NAME=${_NAME/@/_AT_}
  if [[ -e ${_SSHKEY} ]]; then
    log "Note that a period and other symbols aren't allowed to be a key name."
    log "Locally adding ${_SSHKEY} under ${_NAME} label..."
    ncli cluster add-public-key name=${_NAME} file-path=${_SSHKEY}
  fi
}

function Determine_PE {
  local _hold

  log 'Warning: expect errors on lines 1-2, due to non-JSON outputs by nuclei...'
  _hold=$(nuclei cluster.list format=json \
    | jq '.entities[] | select(.status.state == "COMPLETE")' \
    | jq '. | select(.status.resources.network.external_ip != null)')

  if (( $? > 0 )); then
    log "Error: couldn't resolve clusters $?"
    exit 10
  else
    CLUSTER_NAME=$(echo ${_hold} | jq .status.name | tr -d \")
      MY_PE_HOST=$(echo ${_hold} | jq .status.resources.network.external_ip | tr -d \")

    export CLUSTER_NAME MY_PE_HOST
    log "Success: ${CLUSTER_NAME} PE external IP=${MY_PE_HOST}"
  fi
}

function Download {
  local           _attempts=5
  local              _error=0
  local _http_range_enabled= # TODO disabled '--continue-at -'
  local               _loop=0
  local             _output
  local              _sleep=2

  if [[ -z ${1} ]]; then
    _error=33
    log "Error ${_error}: no URL to download!"
    exit ${_error}
  fi

  while true ; do
    (( _loop++ ))
    log "${1}..."
    _output=''
    curl ${CURL_OPTS} ${_http_range_enabled} --remote-name --location ${1}
    _output=$?
    #DEBUG=1; if [[ ${DEBUG} ]]; then log "DEBUG: curl exited ${_output}."; fi

    if (( ${_output} == 0 )); then
      log "Success: ${1##*/}"
      break
    fi

    if (( ${_loop} == ${_attempts} )); then
      log "Error: couldn't download from: ${1}, giving up after ${_loop} tries."
      exit 11
    elif (( ${_output} == 33 )); then
      log "Web server doesn't support HTTP range command, purging and falling back."
      _http_range_enabled=''
      rm -f ${1##*/}
    else
      log "${_loop}/${_attempts}: curl=${_output} ${1##*/} sleep ${_sleep}..."
      sleep ${_sleep}
    fi
  done
}

function remote_exec {
# Argument ${1} = REQIRED: ssh or scp
# Argument ${2} = REQIRED: PE, PC, or LDAP_SERVER
# Argument ${3} = REQIRED: command configuration
# Argument ${4} = OPTIONAL: populated with anything = allowed to fail

  local  _account='nutanix'
  local _attempts=3
  local    _error=99
  local     _host
  local     _loop=0
  local _password="${MY_PE_PASSWORD}"
  local   _pw_init='nutanix/4u' # TODO:140 hardcoded p/w
  local    _sleep=${SLEEP}
  local     _test=0

  # shellcheck disable=SC2153
  case ${2} in
    'PE' )
          _host=${MY_PE_HOST}
      ;;
    'PC' )
          _host=${MY_PC_HOST}
      _password=${_pw_init}
      ;;
    'LDAP_SERVER' )
       _account='root'
          _host=${LDAP_HOST}
      _password=${_pw_init}
         _sleep=7
      ;;
  esac

  if [[ -z ${3} ]]; then
    log 'Error ${_error}: missing third argument.'
    exit ${_error}
  fi

  if [[ ! -z ${4} ]]; then
    _attempts=1
       _sleep=0
  fi

  while true ; do
    (( _loop++ ))
    case "${1}" in
      'SSH' | 'ssh')
       #DEBUG=1; if [[ ${DEBUG} ]]; then log "_test will perform ${_account}@${_host} ${3}..."; fi
        SSHPASS="${_password}" sshpass -e ssh -x ${SSH_OPTS} ${_account}@${_host} "${3}"
        _test=$?
        ;;
      'SCP' | 'scp')
        #DEBUG=1; if [[ ${DEBUG} ]]; then log "_test will perform scp ${3} ${_account}@${_host}:"; fi
        SSHPASS="${_password}" sshpass -e scp ${SSH_OPTS} ${3} ${_account}@${_host}:
        _test=$?
        ;;
      *)
        log "Error ${_error}: improper first argument, should be ssh or scp."
        exit ${_error}
        ;;
    esac

    if (( ${_test} > 0 )) && [[ -z ${4} ]]; then
      _error=22
      log "Error ${_error}: pwd=`pwd`, _test=${_test}, _host=${_host}"
      exit ${_error}
    fi

    if (( ${_test} == 0 )); then
      if [[ ${DEBUG} ]]; then log "${3} executed properly."; fi
      return 0
    elif (( ${_loop} == ${_attempts} )); then
      if [[ -z ${4} ]]; then
        _error=11
        log "Error ${_error}: giving up after ${_loop} tries."
        exit ${_error}
      else
        log "Optional: giving up."
        break
      fi
    else
      log "${_loop}/${_attempts}: _test=$?|${_test}| ${FILENAME} SLEEP ${_sleep}..."
      sleep ${_sleep}
    fi
  done
}

function Dependencies {
  local  _argument
  local     _error
  local     _index
  local       _cpe=/etc/os-release  # CPE = https://www.freedesktop.org/software/systemd/man/os-release.html
  local       _lsb=/etc/lsb-release # Linux Standards Base
  local  _os_found=

  if [[ -z ${1} ]]; then
    _error=20
    log "Error ${_error}: missing install or remove verb."
    exit ${_error}
  elif [[ -z ${2} ]]; then
    _error=21
    log "Error ${_error}: missing package name."
    exit ${_error}
  fi

  if [[ -e ${_lsb} ]]; then
    _os_found="$(grep DISTRIB_ID ${_lsb} | awk -F= '{print $2}')"
  elif [[ -e ${_cpe} ]]; then
    _os_found="$(grep '^ID=' ${_cpe} | awk -F= '{print $2}')"
  fi

  case "${1}" in
    'install')
      log "Install ${2}..."
      export PATH=${PATH}:${HOME}
      if [[ -z `which ${2}` ]]; then
        case "${2}" in
          sshpass )
            if [[ ( ${_os_found} == 'Ubuntu' || ${_os_found} == 'LinuxMint' ) ]]; then
              sudo apt-get install --yes sshpass
            elif [[ ${_os_found} == '"centos"' ]]; then
              # TOFIX: assumption, probably on NTNX CVM or PCVM = CentOS7
              if [[ ! -e sshpass-1.06-2.el7.x86_64.rpm ]]; then
                 _argument=("${SSHPASS_REPOS[@]}")
                    _index=0
                SOURCE_URL=

                if (( ${#_argument[@]} == 0 )); then
                  _error=29
                  log "Error ${_error}: Missing array!"
                  exit ${_error}
                fi

                while (( ${_index} < ${#_argument[@]} ))
                do
                  #log "DEBUG: ${_index} ${_argument[${_index}]}"
                  TryURLs ${_argument[${_index}]}
                  #log "DEBUG: HTTP_CODE=|${HTTP_CODE}|"
                  if (( ${HTTP_CODE} == 200 || ${HTTP_CODE} == 302 )); then
                    SOURCE_URL="${_argument[${_index}]}"
                     HTTP_CODE= #reset
                    break
                  fi
                  ((_index++))
                done
                log "Found ${SOURCE_URL}"

                Download ${SOURCE_URL}
              fi
              sudo rpm -ivh sshpass-1.06-2.el7.x86_64.rpm
              if (( $? > 0 )); then
                _error=31
                log "Error ${_error}: cannot install ${2}."
                exit ${_error}
              fi
              # https://pkgs.org/download/sshpass
              # https://sourceforge.net/projects/sshpass/files/sshpass/
            elif [[ `uname -s` == "Darwin" ]]; then
              brew install https://raw.githubusercontent.com/kadwanev/bigboybrew/master/Library/Formula/sshpass.rb
            fi
            ;;
          jq )
            if [[ ( ${_os_found} == 'Ubuntu' || ${_os_found} == 'LinuxMint' ) ]]; then
              if [[ ! -e jq-linux64 ]]; then
                sudo apt-get install --yes jq
              fi
            elif [[ ${_os_found} == '"centos"' ]]; then
              # https://stedolan.github.io/jq/download/#checksums_and_signatures
              if [[ ! -e jq-linux64 ]]; then
                 _argument=("${JQ_REPOS[@]}")
                    _index=0
                SOURCE_URL=

                if (( ${#_argument[@]} == 0 )); then
                  _error=29
                  log "Error ${_error}: Missing array!"
                  exit ${_error}
                fi

                while (( ${_index} < ${#_argument[@]} ))
                do
                  log "DEBUG: ${_index} ${_argument[${_index}]}"
                  TryURLs ${_argument[${_index}]}
                  log "DEBUG: HTTP_CODE=|${HTTP_CODE}|"
                  if (( ${HTTP_CODE} == 200 || ${HTTP_CODE} == 302 )); then
                    SOURCE_URL="${_argument[${_index}]}"
                     HTTP_CODE= #reset
                    break
                  fi
                  ((_index++))
                done
                log "Found ${SOURCE_URL}"

                Download ${SOURCE_URL}
              fi
              chmod u+x jq-linux64 && ln -s jq-linux64 jq
              PATH+=:`pwd`
              export PATH
            elif [[ `uname -s` == "Darwin" ]]; then
              brew install jq
            fi
            ;;
        esac

        if (( $? > 0 )); then
          _error=98
          log "Error ${_error}: can't install ${2}."
          exit ${_error}
        fi
      else
        log "Success: found ${2}."
      fi
      ;;
    'remove')
      log "Removing ${2}..."
      if [[ ${_os_found} == '"centos"' ]]; then
        #TODO:30 assuming we're on PC or PE VM.
        case "${2}" in
          sshpass )
            sudo rpm -e sshpass
            ;;
          jq )
            rm -f jq jq-linux64
            ;;
        esac
      else
        log "Feature: don't remove Dependencies on Mac OS Darwin, Ubuntu, or LinuxMint."
      fi
      ;;
  esac
}

function Check_Prism_API_Up {
# Argument ${1} = REQUIRED: PE or PC
# Argument ${2} = OPTIONAL: number of attempts
# Argument ${3} = OPTIONAL: number of seconds per cycle
  local _attempts=${ATTEMPTS}
  local    _error=77
  local     _host
  local     _loop=0
  local _password="${MY_PE_PASSWORD}"
  local  _pw_init='Nutanix/4u'
  local    _sleep=${SLEEP}
  local     _test=0

  CheckArgsExist 'ATTEMPTS MY_PE_PASSWORD SLEEP'

  if [[ ${1} == 'PC' ]]; then
    _host=${MY_PC_HOST}
  else
    _host=${MY_PE_HOST}
  fi
  if [[ ! -z ${2} ]]; then
    _attempts=${2}
  fi

  while true ; do
    (( _loop++ ))
    _test=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${_password} \
      -X POST --data '{ "kind": "cluster" }' \
      https://${_host}:9440/api/nutanix/v3/clusters/list \
      | tr -d \") # wonderful addition of "" around HTTP status code by cURL

    if [[ ! -z ${3} ]]; then
      _sleep=${3}
    fi

    if (( ${_test} == 401 )); then
      log "Warning: unauthorized ${1} user or password."
    fi

    if (( ${_test} == 401 )) && [[ ${1} == 'PC' ]] && [[ ${_password} != "${_pw_init}" ]]; then
      _password=${_pw_init}
      log "Warning @${1}: Fallback on ${_host}: try initial password next cycle..."
      _sleep=0 #break
    fi

    if (( ${_test} == 200 )); then
      log "@${1}: successful."
      return 0
    elif (( ${_loop} > ${_attempts} )); then
      log "Warning ${_error} @${1}: Giving up after ${_loop} tries."
      return ${_error}
    else
      log "@${1} ${_loop}/${_attempts}=${_test}: sleep ${_sleep} seconds..."
      sleep ${_sleep}
    fi
  done
}
