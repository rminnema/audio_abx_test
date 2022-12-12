#!/bin/bash

readonly RED=$'\E[31m'
readonly GREEN=$'\E[32m'
readonly YELLOW=$'\E[33m'
readonly BLUE=$'\E[34m'
readonly NOCOLOR=$'\E[0m'

# Functions for printing different message types to the terminal
errr() { printf "%sERROR:%s %s\n" "$RED" "$NOCOLOR" "$*" >&2; exit 1; }
warn() { printf "%sWARNING:%s %s\n" "$YELLOW" "$NOCOLOR" "$*" >&2; }
info() { printf "%sInfo:%s %s\n" "$BLUE" "$NOCOLOR" "$*" >&2; }

# Main program logic
main() {
    term_width=$(tput cols)
    term_lines=$(tput lines)
    config_file="$HOME/audio_abx_test.cfg"
    while (( $# > 0 )); do
        param=$1
        shift
        case "$param" in
            --music_dir)
                music_dir=$1
                shift
                ;;
            --clips_dir)
                clips_dir=$1
                shift
                ;;
            --config_file)
                config_file=$1
                shift
                ;;
            --default_duration)
                default_duration=$1
                shift
                ;;
            *)
                errr "Unrecognized parameter '$param'" ;;
        esac
    done
    if [[ -f "$config_file" ]]; then
        [[ -d "$music_dir" ]] || music_dir=$(awk -F '=' '/^music_dir=/ { print $2 }' "$config_file")
        [[ -d "$clips_dir" ]] || clips_dir=$(awk -F '=' '/^clips_dir=/ { print $2 }' "$config_file")
        [[ "$default_duration" ]] || default_duration=$(awk -F '=' '/^default_duration=/ { print $2 }' "$config_file")
    fi
    default_duration=${default_duration:-30}

    if [[ ! -d "$music_dir" ]]; then
        errr "'$music_dir' directory does not exist."
    fi

    cmnds_notfound=()
    for cmd in ffmpeg vlc mediainfo ffprobe; do
        cmd_set="$cmd=\$(command -v '$cmd') || $cmd=\$(command -v '$cmd.exe')"
        if ! eval "$cmd_set"; then
            cmnds_notfound+=( "$cmd" )
        fi
    done
    if (( ${#cmnds_notfound[@]} > 0 )); then
        errr "At least one command was not found: ${cmnds_notfound[*]}"
    fi

    select_mp3_bitrate
    trap show_results_and_cleanup EXIT

    start_numbered_options_list "Fully random song and timestamp selection"
    numbered_options_list_option "Yes" "Y"
    numbered_options_list_option "No" "N"
    fully_random=$(user_selection "Selection: ")
    echo

    start_numbered_options_list "Source file quality selection"
    numbered_options_list_option "All files" "A"
    numbered_options_list_option "Lossless only" "S"
    numbered_options_list_option "Lossy" "Y"
    source_quality=$(user_selection "Selection: ")
    echo

    if [[ "$source_quality" =~ ^[Aa]$ ]]; then
        audio_file_extensions='flac|alac|wav|aiff|mp3|m4a|aac|ogg|opus|wma'
    elif [[ "$source_quality" =~ ^[Ss]$ ]]; then
        audio_file_extensions='flac|alac|wav|aiff'
    elif [[ "$source_quality" =~ ^[Yy]$ ]]; then
        audio_file_extensions='mp3|m4a|aac|ogg|opus|wma'
    else
        errr "Unexpected condition occurred: source_quality='$source_quality'"
    fi
    find_extensions=( -type f -regextype egrep -iregex ".*\.($audio_file_extensions)" )
    findopts=( -mindepth 3 -maxdepth 3 "${find_extensions[@]}" )
    mapfile -t all_tracks < <(find "$music_dir" "${findopts[@]}")
    mapfile -t all_albums < <(IFS=$'\n'; sed 's|/[^/]*$||' <<< "${all_tracks[*]}" | uniq)
    mapfile -t all_artists < <(IFS=$'\n'; sed 's|/[^/]*$||' <<< "${all_albums[*]}" | uniq)

    if (( ${#all_tracks[@]} == 0 )); then
        errr "No tracks were found in '$music_dir'"
    fi

    track_index=0
    max_idx=$(( ${#all_tracks[@]} - 1 ))
    mapfile -t random_order < <(shuf -i 0-"$max_idx" --random-source=/dev/urandom)
    next_track_is_random=false

    declare -A track_details_map artists_map albums_map titles_map durations_map bitrate_map format_map
    while true; do
        cleanup_async &
        if [[ "$fully_random" =~ ^[Yy]$ ]] || "$next_track_is_random"; then
            random_next_track
        else
            search_next_track
        fi
        generate_track_details
        random_timestamps
        sanitize_timestamps
        create_clip

        x_clip_quality=$(( RANDOM%2 ))
        x_test_attempted=false
        x_test_completed=false
        while true; do
            select_program
            if [[ "$program_selection" =~ ^[NnFf]$ ]]; then
                break
            fi
        done
    done
}

# Reset parameters for numbered options list
start_numbered_options_list() {
    header="$*"
    count=0
    char_options=()
    option_strings=()
}

# Print and store an incrementing list of options for user selection
numbered_options_list_option() {
    local option=$1
    local char=${2^^}

    if [[ "$char" && ! "$char" =~ ^[A-Z]$ ]] || [[ "$char" =~ [EQVW] ]]; then
        errr "Acceptable value for symbolic list option: A-Z excluding EQVW."
    fi

    count=$(( count + 1 ))
    if [[ "$char" ]]; then
        char_options[$count]=$char
        local option_string="$count/$char) $option"
    else
        local option_string="$count) $option"
    fi
    if (( ${#option_string} >= term_width )); then
        local max_field_length=term_width
        option_string=$(ellipsize "$option_string")
    fi
    option_strings+=( "$option_string" )
}

# Calculate the index of the first option to appear on a given page
# The output of `page_index 0` isn't the index of the first option of page 0,
# but the first index of the next page that would go after the current end page if needed
# Invoking the function this way is just convenient given how Bash handles negative array indices
page_index() {
    echo "$(( ${indices[$(( $1 - 1 ))]} + term_lines - ${#reserved_options[$(( $1 - 1 ))]} - header_line - prompt ))"
}

# Prints the numbered options then prompts the user for input and validates against provided options
user_selection() {
    local -a reserved_options indices
    if [[ "$header" ]]; then
        local header_line=1
    else
        local header_line=0
    fi
    local prompt=1
    local page=0
    indices[0]=1
    while (( $(page_index 0) < ${#option_strings[@]} )); do
        if (( page == 0 )); then
            reserved_options[0]=E # next
            reserved_options[1]=V # previous
            indices[1]=$(page_index 1)
        elif (( page == 1 )); then
            reserved_options[0]=EW # next last
            indices[1]=$(page_index 1)
            reserved_options[1]=VE # previous next
            indices[2]=$(page_index 2)
            reserved_options[2]=QV # first previous
        elif (( page == 2 )); then
            reserved_options[1]=VEW # previous next last
            indices[2]=$(page_index 2)
            reserved_options[2]=QVE # first previous next
            indices[3]=$(page_index 3)
            reserved_options[3]=QV # first previous
        elif (( page > 2 )); then
            indices[$(( page - 1 ))]=$(page_index "$(( page - 1 ))")
            reserved_options[$(( page - 1 ))]=QVEW # first previous next last
            indices[$page]=$(page_index "$page")
            reserved_options[$page]=QVE # first previous next
            indices[$(( page + 1 ))]=$(page_index "$(( page + 1 ))")
            reserved_options[$(( page + 1 ))]=QV # first previous
        fi
        page=$(( page + 1 ))
    done
    local pages=$(( page + 1 ))
    page=0

    if [[ "$1" == '--printinfo' ]]; then
        local printinfo=true
        shift
    else
        local printinfo=false
    fi
    local invalid_selection=false

    while true; do
        clear -x >&2
        if "$invalid_selection"; then
            warn "Invalid selection: '$selection'"
            read -rsp "Press enter to continue" _
            clear -x >&2
        fi
        invalid_selection=false
        if "$printinfo"; then
            print_clip_info
            echo
        fi >&2

        [[ "$header" ]] && echo "$header" >&2
        local start=${indices[$page]}
        if [[ "${indices[$(( page + 1 ))]}" ]]; then
            local end=$(( ${indices[$(( page + 1 ))]} - 1 ))
        else
            local end=$(( ${#option_strings[@]} ))
        fi

        for i in $(seq "$start" "$end"); do
            echo "${option_strings[$(( i - 1 ))]}"
        done >&2

        unset meta_options
        local -a meta_options

        page_reserved_options=${reserved_options[$page]}
        for (( i=0; i<${#page_reserved_options}; i++)); do
            option=${page_reserved_options:$i:1}
            meta_options+=( "$option" )
            case "$option" in
                Q)
                    echo "Q) First page" >&2 ;;
                V)
                    echo "V) Previous page" >&2 ;;
                E)
                    echo "E) Next page" >&2 ;;
                W)
                    echo "W) Last page" >&2 ;;
            esac
        done

        local selection
        read -rp "$1" selection

        if [[ -z "$selection" ]]; then
            invalid_selection=true
            continue
        fi

        for option_number in $(seq "$start" "$end"); do
            local char_option=${char_options[$option_number]}
            if [[ "$selection" =~ ^[0-9]+$ ]] && (( 10#$selection == option_number )); then
                if [[ "$char_option" ]]; then
                    echo "$char_option"
                else
                    echo "$selection"
                fi
                return 0
            elif [[ "${selection^^}" == "$char_option" ]]; then
                echo "$char_option"
                return 0
            fi
        done

        if [[ "$selection" =~ ^[0-9]+$ ]]; then
            local meta_options_index=$(( 10#$selection - end - 1 ))
            if (( meta_options_index >= 0 )); then
                selection=${meta_options[$meta_options_index]}
            else
                invalid_selection=true
                continue
            fi
        elif [[ ! "$selection" =~ ^[${reserved_options[$page],,}${reserved_options[$page]^^}]$ ]]; then
            invalid_selection=true
            continue
        fi

        case "${selection^^}" in
            Q)
                page=0 ;;
            W)
                page=$(( pages - 1 )) ;;
            E)
                page=$(( page + 1 )) ;;
            V)
                page=$(( page - 1 )) ;;
            *)
                invalid_selection=true ;;
        esac
    done
}

# Provide the user with main options and take actions accordingly
select_program() {
    start_numbered_options_list
    numbered_options_list_option "A test (original quality)" "A"
    numbered_options_list_option "B test (${bitrate::-1} kbps lossy)" "B"
    if ! "$x_test_completed"; then
        numbered_options_list_option "X test (unknown)" "X"
    fi
    numbered_options_list_option "Re-clip track" "R"
    if ! "$x_test_attempted" || "$x_test_completed"; then
        if [[ "$fully_random" =~ ^[Yy]$ ]]; then
            numbered_options_list_option "Random next track" "N"
        else
            numbered_options_list_option "Find Next track" "F"
            numbered_options_list_option "Random next track" "N"
        fi
    fi
    numbered_options_list_option "Change bitrate" "C"
    if (( ${#results[@]} > 0 )); then
        numbered_options_list_option "Print results" "P"
        numbered_options_list_option "Reset score" "T"
    fi
    if [[ -d "$clips_dir" ]]; then
        numbered_options_list_option "Save clip" "S"
    fi
    numbered_options_list_option "Quit" "U"

    program_selection=$(user_selection --printinfo "Selection: ")
    echo
    case "$program_selection" in
        A|a)
            play_clip "$original_clip" ;;
        B|b)
            play_clip "$lossy_clip" ;;
        X|x)
            if [[ ! -f "$x_clip" ]]; then
                x_clip=$(mktemp --suffix=.wav)
            fi
            original_clip_modtime=$(stat -c "%Y" "$original_clip")
            x_clip_modtime=$(stat -c "%Y" "$x_clip")
            if [[ ! -s "$x_clip" ]] || (( original_clip_modtime > x_clip_modtime )); then
                if (( x_clip_quality )); then
                    format=original
                    cp "$original_clip" "$x_clip"
                else
                    format=lossy
                    cp "$lossy_clip" "$x_clip"
                fi
            fi
            play_clip "$x_clip"
            x_test
            ;;
        S|s)
            save_clip ;;
        P|p)
            print_results ;;
        C|c)
            cleanup_async &
            select_mp3_bitrate
            create_clip
            ;;
        T|t)
            reset_score ;;
        N|n)
            if ! "$x_test_attempted" && ! "$x_test_completed"; then
                add_result skipped
            fi
            next_track_is_random=true
            ;;
        F|f)
            if ! "$x_test_attempted" && ! "$x_test_completed"; then
                add_result skipped
            fi
            next_track_is_random=false
            ;;
        U|u)
            if ! "$x_test_completed"; then
                add_result quit
            fi
            quit=true
            exit 0
            ;;
        R|r)
            cleanup_async &
            generate_timestamps
            create_clip
            ;;
        *)
            return 1 ;;
    esac
}

# Generate the timestamps to be used in the clip
generate_timestamps() {
    if [[ "$fully_random" =~ ^[Yy]$ ]]; then
        random_timestamps
    else
        start_numbered_options_list "Input timestamps manually or have them randomly generated?"
        numbered_options_list_option "Random timestamps" "R"
        numbered_options_list_option "Manual timestamps" "M"
        local timestamp_selection
        timestamp_selection=$(user_selection --printinfo "Selection: ")
        echo
        if [[ "$timestamp_selection" =~ ^[Mm]$ ]]; then
            user_timestamps
        elif [[ "$timestamp_selection" =~ ^[Rr]$ ]]; then
            if ! random_timestamps; then
                warn "Something went wrong with random timestamps"
                return 1
            fi
        elif [[ "$timestamp_selection" =~ ^[Cc]$ ]]; then
            return 0
        else
            errr "Unexpected condition occurred: timestamp_selection='$timestamp_selection'"
        fi
    fi
    sanitize_timestamps
}

# Add track and test result information to the list of results
add_result() {
    local track_info=${track_details_map["$track"]}
    local numresults=$(( ${#results[@]} + 1 ))
    if [[ "$1" == skipped ]]; then
        skipped=$(( skipped + 1 ))
        local result="$numresults|$track_info|${1^}|${YELLOW}${1^}${NOCOLOR}"
    elif [[ "$1" == quit ]]; then
        local result="$numresults|$track_info|${1^}|${YELLOW}${1^}${NOCOLOR}"
    elif [[ "$1" == forfeit ]]; then
        incorrect=$(( incorrect + 1 ))
        local result="$numresults|$track_info|${1^}|${RED}${1^}${NOCOLOR}"
    elif [[ "$1" && "$2" && "$1" == "$2" ]]; then
        correct=$(( correct + 1 ))
        local result="$numresults|$track_info|${1^}|${GREEN}${2^}${NOCOLOR}"
    elif [[ "$1" && "$2" && "$1" != "$2" ]]; then
        incorrect=$(( incorrect + 1 ))
        local result="$numresults|$track_info|${1^}|${RED}${2^}${NOCOLOR}"
    else
        return 1
    fi
    results+=( "$result" )
}

# Choose the MP3 bitrate for the lossy clip
select_mp3_bitrate() {
    clear -x >&2
    start_numbered_options_list "Select a bitrate for MP3 compression of the lossy file."
    if [[ "$last_bitrate" ]]; then
        warn "Changing your bitrate will reset your score and progress."
    fi
    for btrt in 32 64 96 112 128 256 320; do
        if [[ "$bitrate" && "$btrt" == "${bitrate::-1}" ]]; then
            numbered_options_list_option "${GREEN}${btrt} kbps${NOCOLOR}"
        else
            numbered_options_list_option "$btrt kbps"
        fi
    done
    numbered_options_list_option "Custom" "C"
    local bitrate_selection
    bitrate_selection=$(user_selection "Selection: ")
    echo
    case "$bitrate_selection" in
        1)
            bitrate=32k ;;
        2)
            bitrate=64k ;;
        3)
            bitrate=96k ;;
        4)
            bitrate=112k ;;
        5)
            bitrate=128k ;;
        6)
            bitrate=256k ;;
        7)
            bitrate=320k ;;
        8|C|c)
            while true; do
                read -r -p "Bitrate (between 32k and 320k): " bitrate
                if [[ ! "$bitrate" =~ k ]]; then
                    bitrate+=k
                fi
                if [[ ! "$bitrate" =~ ^[0-9]+k$ ]]; then
                    errr "You must provide a bitrate in the standard format"
                fi
                break
            done
            if (( ${bitrate::-1} < 32 )); then
                bitrate=32k
            elif (( ${bitrate::-1} > 320 )); then
                bitrate=320k
            fi
            info "Bitrate selection is $bitrate"
            ;;
        *)
            errr "Input must be between 1 and $count" ;;
    esac
    if [[ -z "$last_bitrate" || "$bitrate" != "$last_bitrate" ]]; then
        reset_score
    fi
    last_bitrate=$bitrate
}

# Resets the user's score to zero and empties their results list
reset_score() {
    print_results
    accuracy=0
    correct=0
    incorrect=0
    skipped=0
    results=()
    x_test_attempted=false
    x_test_completed=false
}

search_next_track() {
    action=artist
    nomatch=false
    while true; do
        case "$action" in
            artist) unset matched_artists
                    artist_search
                    ;;
            album)  unset matched_albums
                    album_search
                    ;;
            track)  unset matched_tracks
                    track_search
                    ;;
            selected)
                    break ;;
        esac
    done
}

# Takes as input a UTF8 array
# Converts the array to ASCII and searches against the ASCII array with the search_string
# Returns an array of matching indices to the original UTF8 array
utf8_array_search() {
    IFS=$'\n'
    iconv -f utf8 -t ascii//TRANSLIT <<< "$*" |
        awk -F '/' '{ print $NF }' |
        grep -Ein "${search_string:-.*}" |
        awk -F ':' '{ print $1 }' |
        sed 's/$/ - 1/' |
        bc
}

# Search for an artist with a given string
artist_search() {
    clear -x >&2
    if "$nomatch"; then
        warn "No artists matched the search string provided."
    fi
    local search_string
    read -rp "Artist search string: " search_string

    local -a matched_artist_indices
    mapfile -t matched_artist_indices < <(utf8_array_search "${all_artists[@]}")

    if (( ${#matched_artist_indices[@]} == 0 )); then
        nomatch=true
        return 1
    fi

    nomatch=false

    start_numbered_options_list
    for index in "${matched_artist_indices[@]}"; do
        numbered_options_list_option "$(basename "${all_artists["$index"]}")"
        matched_artists+=( "${all_artists["$index"]}" )
    done
    (( ${#matched_artists[@]} > 1 )) && numbered_options_list_option "Search albums of all above artists" "A"
    numbered_options_list_option "Random track from the above artists" "N"
    numbered_options_list_option "Retry search artist again" "R"

    local artist_selection
    artist_selection=$(user_selection "Select an artist to search their albums: ")
    if (( artist_selection == count )) || [[ "$artist_selection" =~ ^[Rr]$ ]]; then
        action=artist
    elif (( artist_selection == count - 1 )) || [[ "$artist_selection" =~ ^[Nn]$ ]]; then
        track=$(find "${matched_artists[@]}" -mindepth 2 -maxdepth 2 "${find_extensions[@]}" | sort -R | head -n 1)
        action=selected
    elif (( ${#matched_artists[@]} > 1 && artist_selection == count - 2 )) || [[ "$artist_selection" =~ ^[Aa]$ ]]; then
        action=album
    elif (( artist_selection <= count - 2 )); then
        matched_artists=( "${matched_artists[$(( artist_selection - 1 ))]}" ) # Search albums of a single artist
        action=album
    fi
}

# Search for an album with a given string
album_search() {
    clear -x >&2
    unset album_selection count
    start_numbered_options_list
    local search_string
    local findopts=( -mindepth 2 -maxdepth 2 "${find_extensions[@]}" )
    read -rp "Album search string: " search_string
    local -a albums
    if (( ${#matched_artists[@]} > 0 )); then
        mapfile -t albums < <(find "${matched_artists[@]}" "${findopts[@]}" | sed 's|/[^/]*$||' | sort -u)
    else
        albums=( "${all_albums[@]}" )
    fi

    local -a matched_album_indices
    mapfile -t matched_album_indices < <(utf8_array_search "${albums[@]}")

    unset matched_albums
    for index in "${matched_album_indices[@]}"; do
        numbered_options_list_option "$(sed -E 's|^.*/([^/]*)/([^/]*)$|\1 - \2|' <<< "${albums["$index"]}")"
        matched_albums+=( "${albums["$index"]}" )
    done
    (( ${#matched_albums[@]} > 1 )) && numbered_options_list_option "Search tracks of above albums" "A"
    numbered_options_list_option "Random track from the above albums" "N"
    numbered_options_list_option "Search album again" "L"
    numbered_options_list_option "Search artist again" "R"

    local album_selection
    album_selection=$(user_selection "Select an album: ")
    if (( album_selection == count )) || [[ "$album_selection" =~ ^[Rr]$ ]]; then
        action=artist
    elif (( album_selection == count - 1 )) || [[ "$album_selection" =~ ^[Ll]$ ]]; then
        action=album
    elif (( album_selection == count - 2 )) || [[ "$album_selection" =~ ^[Nn]$ ]]; then
        track=$(find "${matched_albums[@]}" -mindepth 1 -maxdepth 1 "${find_extensions[@]}" | sort -R | head -n 1)
        action=selected
    elif (( ${#matched_albums[@]} > 1 && album_selection == count - 3 )) || [[ "$album_selection" =~ ^[Aa]$ ]]; then
        action=track
    elif (( album_selection <= count - 3 )); then
        matched_albums=( "${matched_albums[$(( album_selection - 1 ))]}" ) # Search one album
        action=track
    fi
}

# Search for a track with a given string
track_search() {
    clear -x >&2
    local -a tracks matched_tracks matched_track_indices
    local search_string artist_name album_name track_name track_number track_selection
    local findopts=( -mindepth 1 -maxdepth 1 "${find_extensions[@]}" )
    start_numbered_options_list
    read -rp "Track title search string: " search_string
    if (( ${#matched_albums[@]} > 0 )); then
        mapfile -t tracks < <(find "${matched_albums[@]}" "${findopts[@]}")
    elif (( ${#matched_artists[@]} > 0 )); then
        mapfile -t tracks < <(find "${matched_artists[@]}" "${findopts[@]}")
    else
        tracks=( "${all_tracks[@]}" )
    fi

    mapfile -t matched_track_indices < <(utf8_array_search "${tracks[@]}")

    for index in "${matched_track_indices[@]}"; do
        track=${tracks[$index]}
        numbered_options_list_option "$(sed -E 's|^.*/([^/]*)/([^/]*)/([^/]*)$|\1 - \2 - #\3|' <<< "$track")"
        matched_tracks+=( "$track" )
    done
    numbered_options_list_option "Random track from above" "N"
    numbered_options_list_option "Search track again" "T"
    numbered_options_list_option "Search album again" "L"
    numbered_options_list_option "Search artist again" "R"

    track_selection=$(user_selection "Select a track: ")
    if (( track_selection == count )) || [[ "$track_selection" =~ ^[Rr]$ ]]; then
        action=artist
    elif (( track_selection == count - 1 )) || [[ "$track_selection" =~ ^[Ll]$ ]]; then
        action=album
    elif (( track_selection == count - 2 )) || [[ "$track_selection" =~ ^[Tt]$ ]]; then
        action=track
    elif (( track_selection == count - 3 )) || [[ "$track_selection" =~ ^[Nn]$ ]]; then
        track=$(IFS=$'\n'; sort -R <<< "${matched_tracks[*]}" | head -n 1)
        action=selected
    else
        track="${matched_tracks[$(( track_selection - 1 ))]}"
        generate_track_details
        action=selected
    fi
}

# Iterate through the pre-generated array of random indices
# and use each random index to select a track
random_next_track() {
    random_index=${random_order[$track_index]}
    track=${all_tracks[$random_index]}
    if (( ++track_index >= ${#all_tracks[@]} )); then
        track_index=0
    fi
}

# Read and store track metadata such as duration, title, album, artist, bitrate, and encoding format
generate_track_details() {
    if [[ "${track_details_map["$track"]}" ]]; then
        return 0
    fi
    if [[ "${ffprobe:?}" == *ffprobe.exe ]]; then
        local ffprobe_track=$(wslpath -w "$track")
    else
        local ffprobe_track=$track
    fi

    local fmt="default=noprint_wrappers=1:nokey=1"
    local ffprobe_opts=( -v fatal -select_streams a -show_entries "stream=duration" -of "$fmt" "$ffprobe_track" )
    local track_duration=$("${ffprobe:?}" "${ffprobe_opts[@]}" | sed 's/\r//g')
    local track_duration_int=$(grep -Eo "^[0-9]*" <<< "$track_duration")
    durations_map["$track"]=$track_duration_int

    if [[ "${mediainfo:?}" == *mediainfo.exe ]]; then
        local mediainfo_track=$(wslpath -w "$track")
    else
        local mediainfo_track=$track
    fi
    local mediainfo_output='General;%Artist%|%Album%|%Title%|%BitRate%|%Format%'
    local track_artist track_album track_title track_bitrate track_format
    IFS='|' read -r track_artist track_album track_title track_bitrate track_format < \
            <("${mediainfo:?}" --output="$mediainfo_output" "$mediainfo_track")

    local max_field_length=$(( (term_width - 32)/3 ))
    track_artist_el=$(ellipsize "$track_artist")
    track_album_el=$(ellipsize "$track_album")
    track_title_el=$(ellipsize "$track_title")

    artists_map["$track"]=$track_artist
    albums_map["$track"]=$track_album
    titles_map["$track"]=$track_title
    bitrate_map["$track"]=$(( track_bitrate / 1024 ))
    format_map["$track"]=$track_format
    track_details_map["$track"]="$track_artist_el|$track_album_el|$track_title_el"
}

# Truncates lengthy fields and adds ellipsis to indicate such
ellipsize() {
    local cut_length=$(( max_field_length - 3 ))
    sed -Ee "s/(.{$cut_length})....*$/\1.../" -e 's/\s*\.\.\.$/.../' <<< "$*"
}

# Wrapper around the async portion, allocates the temp filenames
create_clip() {
    original_clip=$(mktemp --suffix=.wav)
    lossy_clip=$(mktemp --suffix=.wav)
    tmp_mp3=$(mktemp --suffix=.mp3)
    if [[ "${ffmpeg:?}" == *ffmpeg ]]; then
        local ffmpeg_track=$track
        local ffmpeg_original_clip=$original_clip
        local ffmpeg_lossy_clip=$lossy_clip
    else
        local ffmpeg_track=$(wslpath -w "$track")
        local ffmpeg_original_clip=$(wslpath -w "$original_clip")
        local ffmpeg_lossy_clip=$(wslpath -w "$lossy_clip")
    fi

    create_clip_async &
    create_clip_pid=$!
}

# Allows terminal to return to the user while program cleans up
cleanup_async() {
    if kill -0 "$create_clip_pid" 2>/dev/null; then
        kill "$create_clip_pid" 2>/dev/null
    fi
    while kill -0 "$vlc_pid" 2>/dev/null; do
        sleep 0.1
    done
    while kill -0 "$create_clip_pid" 2>/dev/null; do
        sleep 0.1
    done
    rm -f "$original_clip" "$lossy_clip" "$tmp_mp3" "$x_clip"
}

# Create an original-quality clip and a lossy clip from a given track at the given timestamps
# Obfuscate both original quality and lossy clips as .wav so it cannot easily be determined which is the X file
create_clip_async() {
    "${ffmpeg:?}" -nostdin -loglevel error -y -i "$ffmpeg_track" \
        -ss "$startsec" -t "$clip_duration" "$ffmpeg_original_clip" \
        -ss "$startsec" -t "$clip_duration" -b:a "$bitrate" "$tmp_mp3"

    "${ffmpeg:?}" -nostdin -loglevel error -y -i "$tmp_mp3" "$ffmpeg_lossy_clip"
}

# Generate random timestamps to use for clipping
random_timestamps() {
    clip_duration=$default_duration
    local track_duration_int=${durations_map["$track"]}
    if (( track_duration_int < clip_duration)); then
        clip_duration=$track_duration_int
    fi
    startsec=$(shuf -i 0-"$(( track_duration_int - clip_duration ))" -n 1 --random-source=/dev/urandom)
    endsec=$(( startsec + clip_duration ))
}

# Convert seconds to a string in the form of HH:MM:SS for HH > 00 or else MM:SS
seconds_to_timespec() {
    date -u --date=@"$1" +%H:%M:%S | sed -r 's/00:?([0-9]{2}:?[0-9]{2})/\1/g'
}

# Prompt the user for timestamps to use for clipping
user_timestamps() {
    unset startsec endsec
    local startts endts
    while [[ -z "$startsec" ]]; do
        read -rp "Start timestamp: " startts
        if [[ -z "$startts" || "$startts" =~ ^[Rr]$ ]]; then
            info "Selecting random timestamp for a $default_duration second clip"
            random_timestamps
            return 0
        elif [[ "$startts" =~ ^[SsFf]$ ]]; then
            startsec=0
        else
            startsec=$(parse_time_to_seconds "$startts") || unset startsec
        fi
    done

    if [[ "$startts" =~ ^[Ff]$ ]]; then
        endsec=${durations_map["$track"]}
    fi
    until [[ "$endsec" ]]; do
        read -rp "End timestamp: " endts
        if [[ -z "$endts" ]]; then
            endsec=$(( startsec + default_duration ))
        elif [[ "$endts" =~ ^[Ee]$ ]]; then
            endsec=${durations_map["$track"]}
        else
            endsec=$(parse_time_to_seconds "$endts") || unset endsec
        fi
    done
}

# Convert a time given in [[HH:]MM:]SS to seconds
# Also convert times 'date' understands like "5 minutes 32 seconds"
parse_time_to_seconds() {
    local timespec=$1
    if [[ "$timespec" =~ ^[0-9:]*$ ]]; then
        local seconds minutes hours
        read -r seconds minutes hours _ < <(awk -F ':' '{ for (i=NF;i>0;i--) printf("%s ",$i)}' <<< "$timespec")
        seconds=${seconds:-0}
        minutes=${minutes:-0}
        hours=${hours:-0}
        if (( 10#$seconds > 59 )); then
            minutes=$(( minutes + 1 ))
            seconds=$(( seconds - 60 ))
        fi
        if (( 10#$minutes > 59 )); then
            hours=$(( hours + 1 ))
            minutes=$(( minutes - 60 ))
        fi
        awk -v s="$seconds" -v m="$minutes" -v h="$hours" 'BEGIN { printf("%s",s + 60*m + 60*60*h) }'
    else
        # Hope the user gave the time in some other format date understands
        date -u --date="January 1 1970 + $timespec" +%s
    fi
}

# Ensure that timestamps are valid
sanitize_timestamps() {
    # Ensure the start is before the end
    if (( $(bc <<< "$endsec < $startsec") )); then
        local tmpvar=$startsec
        startsec=$endsec
        endsec=$tmpvar
    fi
    if (( $(bc <<< "$endsec == $startsec") )); then
        endsec=$(bc <<< "$endsec + 1")
    fi

    # Ensure no negative start or end times
    if (( $(bc <<< "$startsec < 0") )); then
        startsec=0
    fi
    if (( $(bc <<< "$endsec < 1") )); then
        endsec=1
    fi

    local track_duration_int=${durations_map["$track"]}
    # Ensure the clip doesn't start or extend past the end of the track
    if (( $(bc <<< "$startsec >= $track_duration_int") )); then
        startsec=$(( track_duration_int - 1 ))
    fi
    if (( $(bc <<< "$endsec > $track_duration_int") )); then
        endsec=$(( track_duration_int ))
    fi

    clip_duration=$(bc <<< "$endsec - $startsec")
}

# Play the clip in VLC media player
play_clip() {
    local vlc_clip
    if [[ "${vlc:?}" == *vlc.exe ]]; then
        vlc_clip=$(wslpath -w "$1")
    else
        vlc_clip=$1
    fi

    if kill -0 "$vlc_pid" 2>/dev/null; then
        echo
        info "You must close the current instance of VLC to open another one."
        wait "$vlc_pid"
    fi
    if kill -0 "$create_clip_pid" 2>/dev/null; then
        echo
        info "Please wait while the encoding job finishes."
        wait "$create_clip_pid"
    fi
    "${vlc:?}" "$vlc_clip" &>/dev/null &
    vlc_pid=$!
}

# Randomly selects the quality for the clip and plays it for the user, then
# asks the user to guess whether the clip is original quality or MP3 compressed
# Allows user to return to menu to try A or B test again or re-clip the current
# track, but the user will not be able to skip ahead to the next track
x_test() {
    local forfeit=false
    x_test_attempted=true
    start_numbered_options_list
    numbered_options_list_option "Guess" "G"
    numbered_options_list_option "Retry" "R"
    numbered_options_list_option "Forfeit" "F"
    local retry_guess_forfeit
    retry_guess_forfeit=$(user_selection --printinfo "Selection: ")
    if [[ "$retry_guess_forfeit" =~ ^[Rr]$ ]]; then
        return 0
    elif [[ "$retry_guess_forfeit" =~ ^[Ff]$ ]]; then
        forfeit=true
        echo
        info "You forfeited. The file was ${format^^}"
        add_result forfeit
    elif [[ ! "$retry_guess_forfeit" =~ ^[Gg]$ ]]; then
        errr "Unexpected condition occurred: retry_guess_forfeit='$retry_guess_forfeit'"
    fi
    if ! "$forfeit"; then
        while [[ ! "$confirmation" =~ ^[Yy]$ ]]; do
            start_numbered_options_list "Which quality level do you hear?"
            numbered_options_list_option "Original quality" "O"
            numbered_options_list_option "Lossy compression" "L"
            local guess
            guess=$(user_selection --printinfo "Selection: ")
            if [[ "$guess" =~ ^[Oo]$ ]]; then
                local guess_fmt=original
            elif [[ "$guess" =~ ^[Ll]$ ]]; then
                local guess_fmt=lossy
            else
                errr "Unexpected condition occurred: guess='$guess'"
            fi
            start_numbered_options_list "You guessed $guess_fmt. Are you sure?"
            numbered_options_list_option "Yes" "Y"
            numbered_options_list_option "No" "N"
            local confirmation
            confirmation=$(user_selection --printinfo "Selection: ")
        done
        echo
        if [[ "$guess_fmt" == "$format" ]]; then
            echo "${GREEN}CORRECT!${NOCOLOR} The file was ${format^^} and your guess was ${guess_fmt^^}"
        else
            echo "${RED}INCORRECT.${NOCOLOR} The file was ${format^^} and your guess was ${guess_fmt^^}"
        fi
        add_result "$format" "$guess_fmt"
    fi
    accuracy=$(bc <<< "100 * $correct / ($correct + $incorrect)")
    echo "Your accuracy is now $accuracy% ($correct/$(( correct + incorrect )))"
    echo "$skipped tracks skipped"
    echo
    x_test_completed=true
    read -rsp "Press enter to continue:" _
    echo
}

# Save either the lossy or original clip with a user-friendly name to the clips_dir
# Optional lossless compression to FLAC
save_clip() {
    start_numbered_options_list "Select a quality level to save in."
    numbered_options_list_option "Save original quality" "O"
    numbered_options_list_option "Save lossy quality" "L"
    numbered_options_list_option "Cancel and return to main menu" "C"
    local save_choice_1
    save_choice_1=$(user_selection "Selection: ")
    echo
    if [[ "$save_choice_1" =~ ^[Oo]$ ]]; then
        local compression=original
        local clip_to_save="$original_clip"
    elif [[ "$save_choice_1" =~ ^[Ll]$ ]]; then
        local compression=lossy
        local clip_to_save="$lossy_clip"
    elif [[ "$save_choice_1" =~ ^[Cc]$ ]]; then
        return 0
    else
        errr "Unexpected condition occurred: save_choice_1='$save_choice_1'"
    fi
    start_numbered_options_list "Select a file format to save in."
    numbered_options_list_option "Save as WAV" "A"
    numbered_options_list_option "Save as FLAC" "F"
    numbered_options_list_option "Cancel and return to main menu" "C"
    local save_choice_2
    save_choice_2=$(user_selection "Selection: ")
    if [[ "$save_choice_2" =~ ^[Aa]$ ]]; then
        local file_fmt=wav
    elif [[ "$save_choice_2" =~ ^[Ff]$ ]]; then
        local file_fmt=flac
    elif [[ "$save_choice_2" =~ ^[Cc]$ ]]; then
        return 0
    else
        errr "Unexpected condition occurred: save_choice_2='$save_choice_2'"
    fi
    local artist=${artists_map["$track"]}
    local album=${albums_map["$track"]}
    local title=${titles_map["$track"]}
    local save_file_basename=$(sed 's|/|-|g' <<< "$artist -- $album -- $title")
    local start_ts=$(seconds_to_timespec "$startsec" | tr -d ':')
    local end_ts=$(seconds_to_timespec "$endsec" | tr -d ':')
    local save_file="$clips_dir/$save_file_basename -- $compression.$start_ts.$end_ts.$file_fmt"

    if kill -0 "$create_clip_pid" 2>/dev/null; then
        echo
        info "Please wait while clip creation finishes."
        wait "$create_clip_pid"
    fi
    echo
    if [[ "$save_choice_2" =~ ^[Aa]$ ]]; then
        if cp "$clip_to_save" "$save_file"; then
            echo "${compression^} clip saved to:"
            echo "$save_file"
        else
            warn "Could not save $save_file"
        fi
    elif [[ "$save_choice_2" =~ ^[Ff]$ ]]; then
        if [[ "${ffmpeg:?}" == *ffmpeg.exe ]]; then
            touch "$save_file"
            save_file=$(wslpath -w "$save_file")
        fi
        if "${ffmpeg:?}" -nostdin -y -loglevel error -i "$clip_to_save" "$save_file"; then
            echo "${compression^} clip saved to:"
            echo "$save_file"
        else
            warn "Could not save $save_file"
        fi
    fi
    read -rsp "Press enter to continue:" _
    echo
}

# Print out details about the clip
print_clip_info() {
    local max_field_length=$(( term_width - $(printf "Artist: " | wc -c) ))
    local artist_el=$(ellipsize "${artists_map["$track"]}")
    echo "Artist: $artist_el"

    max_field_length=$(( term_width - $(printf "Album: " | wc -c) ))
    local album_el=$(ellipsize "${albums_map["$track"]}")
    echo "Album: $album_el"

    max_field_length=$(( term_width - $(printf "Title: " | wc -c) ))
    local title_el=$(ellipsize "${titles_map["$track"]}")
    echo "Title: $title_el"

    echo "Avg. Bitrate: ${bitrate_map["$track"]} kbps"
    echo "Format: ${format_map["$track"]}"
    echo "Track duration: $(seconds_to_timespec "${durations_map["$track"]}")"
    [[ "$startsec" ]] && echo "Clip from $(seconds_to_timespec "$startsec") - $(seconds_to_timespec "$endsec")"
}

# Generate a printout of the results, showing all tracks that have been presented so far
# Along with the results and guesses for each X test
print_results() {
    if (( ${#results[@]} > 0 )); then
        clear -x >&2
        if [[ -z "$quit" ]]; then
            echo "Current track info:"
            {
                echo "Artist|Album|Title"
                echo "${track_details_map["$track"]}"
            } | column -ts '|'
            echo
        fi
        echo "Bitrate: ${bitrate::-1} kbps"
        {
            echo "Number|Artist|Album|Track|Result|Guess"
            for result in "${results[@]}"; do
                echo "$result"
            done
        } | column -ts '|'
        local tries=$(( correct + incorrect ))
        printf "%s%% accuracy, " "$accuracy"
        printf "%s correct out of " "$correct"
        printf "%s tries, " "$tries"
        printf "%s skipped\n" "$skipped"
        if [[ -z "$quit" ]]; then
            read -rsp "Press enter to continue:" _
            echo
        fi
    fi
}

# Trap function to run on exit, displaying the results and deleting all files used
show_results_and_cleanup() {
    cleanup_async &
    print_results
}

main "$@"
