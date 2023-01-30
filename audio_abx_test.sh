#!/bin/bash

readonly RED=$'\E[31m'
readonly GREEN=$'\E[32m'
readonly YELLOW=$'\E[33m'
readonly BLUE=$'\E[34m'
readonly NOCOLOR=$'\E[0m'

# Functions for printing different message types to the terminal
errr() { printf "%sERROR:%s %s\n" "$RED" "$NOCOLOR" "$*"; exit 1; }
warn() { printf "%sWARNING:%s %s\n" "$YELLOW" "$NOCOLOR" "$*"; }
info() { printf "%sInfo:%s %s\n" "$BLUE" "$NOCOLOR" "$*"; }

# Main program logic
main() {
    # Detect if stdout or stderr is being piped or redirected
    if [[ ! -t 1 || ! -t 2 ]]; then
        output_warning=true
    fi

    # Just print everything to the terminal
    exec >/dev/tty 2>&1

    if [[ "$output_warning" == true ]]; then
        warn "This program prints to the terminal only!"
        echo "To log output, use the --output_file command line option"
        read -rsp "Press enter to continue." _
    fi

    # Grab terminal lines and columns
    terminal_width=$(tput cols)
    terminal_lines=$(tput lines)
    config_file="$HOME/audio_abx_test.cfg"

    # Process command line parameters
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
            --output_file)
                output_file=$1
                shift
                ;;
            --overwrite)
                overwrite=true
                ;;
            *)
                errr "Unrecognized parameter '$param'" ;;
        esac
    done

    if [[ "$output_file" ]]; then
        if [[ ! -f "$output_file" || "$overwrite" == true ]]; then
            # Output to terminal, and simultaneously strip color and other control codes from output
            # before saving it to the specified output file
            exec > >(tee /dev/tty | sed -r 's/\x1B\[([0-9]{1,3}(;[0-9]{1,2};?)?)?[mGKHJ]//g' > "$output_file") 2>&1
        else
            errr "$output_file exists but --overwrite was not given. Exiting."
        fi
    fi

    # Process config file
    if [[ -f "$config_file" ]]; then
        [[ -d "$music_dir" ]] || music_dir=$(awk -F '=' '/^music_dir=/ { print $2 }' "$config_file")
        [[ -d "$clips_dir" ]] || clips_dir=$(awk -F '=' '/^clips_dir=/ { print $2 }' "$config_file")
        [[ "$default_duration" ]] || default_duration=$(awk -F '=' '/^default_duration=/ { print $2 }' "$config_file")
    fi
    default_duration=${default_duration:-30}

    if [[ ! -d "$music_dir" ]]; then
        errr "'$music_dir' directory does not exist."
    fi

    # Check that dependencies exist, prefer Linux executables but allow Windows .exe files
    cmnds_notfound=()
    for cmd in ffmpeg vlc mediainfo ffprobe; do
        cmd_set="$cmd=\$(command -v '$cmd') || $cmd=\$(command -v '$cmd.exe')"
        if ! eval "$cmd_set"; then
            cmnds_notfound+=( "$cmd" )
        fi
    done
    if (( ${#cmnds_notfound[@]} > 0 )); then
        errr "At least one dependency was not found: ${cmnds_notfound[*]}"
    fi

    select_mp3_bitrate

    start_numbered_options_list "Fully random song and timestamp selection"
    numbered_options_list_option "Yes" "Y"
    numbered_options_list_option "No" "N"
    fully_random=$(user_selection "Selection: ")

    start_numbered_options_list "Source file quality selection"
    numbered_options_list_option "All files" "A"
    numbered_options_list_option "Lossless only" "S"
    numbered_options_list_option "Lossy only" "Y"
    source_quality=$(user_selection "Selection: ")

    if [[ "$source_quality" =~ ^[Aa]$ ]]; then
        # Selection: "All"
        audio_file_extensions='flac|alac|wav|aiff|mp3|m4a|aac|ogg|opus|wma'
    elif [[ "$source_quality" =~ ^[Ss]$ ]]; then
        # Selection: "Lossless only"
        audio_file_extensions='flac|alac|wav|aiff'
    elif [[ "$source_quality" =~ ^[Yy]$ ]]; then
        # Selection: "Lossy only"
        audio_file_extensions='mp3|m4a|aac|ogg|opus|wma'
    else
        errr "Unexpected condition occurred: source_quality='$source_quality'"
    fi
    # Map all tracks, albums, and artists of the selected quality to arrays
    find_extensions=( -type f -regextype egrep -iregex ".*\.($audio_file_extensions)" )
    findopts=( -mindepth 3 -maxdepth 3 "${find_extensions[@]}" )
    mapfile -t all_tracks < <(find "$music_dir" "${findopts[@]}" | sort)
    mapfile -t all_albums < <(printf '%s\n' "${all_tracks[@]}" | sed 's|/[^/]*$||' | uniq)
    mapfile -t all_artists < <(printf '%s\n' "${all_albums[@]}" | sed 's|/[^/]*$||' | uniq)

    if (( ${#all_tracks[@]} == 0 )); then
        errr "No tracks were found in '$music_dir'"
    fi

    current_track_index=0
    max_track_index=$(( ${#all_tracks[@]} - 1 ))

    # Generate a randomly-ordered array of all integers from 0 to max_track_index with each value used exactly once
    # Linearly iterating through this array and using each value as an index to the all_tracks() array gives us
    # random track selection without repeats
    mapfile -t random_track_indices < <(shuf -i 0-"$max_track_index" --random-source=/dev/urandom)
    next_track_is_random=false

    # associative arrays for mapping tracks to various
    # track attributes gathered from ffprobe and mediainfo
    declare -A track_details_map artists_map albums_map titles_map durations_map bitrate_map format_map
    trap exit_trap EXIT
    while true; do
        # Perform cleanup tasks at beginning of each loop
        cleanup

        # If the user indicated they wanted a random track or that track selection should always be random,
        # then select a random track. Otherwise, let user search for the next track
        if [[ "$fully_random" =~ ^[Yy]$ ]] || "$next_track_is_random"; then
            random_next_track
        else
            search_next_track
        fi
        # Fill details for the current track into the associative arrays declared earlier
        generate_track_details
        # Always randomly generate the timestamps for the first clip of a given track
        random_timestamps
        # Ensure timestamps are reasonable
        sanitize_timestamps
        # Generate the A and B clips
        create_clip

        # decides whether the unknown x-clip is losslessly or MP3-encoded
        x_clip_quality=$(( RANDOM%2 ))

        x_test_attempted=false
        x_test_completed=false
        while true; do
            # Present choices to the user about what to do, e.g. listen to the A or B clips,
            # perform the x-test, save clips to disk, and more
            select_program
            # Move to the next track if the user indicated to do so
            if [[ "$program_selection" =~ ^[NnFf]$ ]]; then
                break
            fi
        done
    done
}

# Reset parameters for numbered options list
start_numbered_options_list() {
    # options_list_header is an optional string displayed before the numbered options
    options_list_header="$*"
    char_options=()
    option_strings=()
}

# Store an option into incrementing list of options for user selection
numbered_options_list_option() {
    # The option is a string that should explain to the user what happens when they select the option
    local option=$1
    # Char is a character that the user can enter to select the option instead of just the number value of the option
    local char=${2^^}

    # E, Q, V, and W are reserved for use by page selection options
    if [[ "$char" && ! "$char" =~ ^[A-Z]$ ]] || [[ "$char" =~ [EQVW] ]]; then
        errr "Acceptable value for symbolic list option: A-Z excluding EQVW."
    fi

    if [[ "$char" ]]; then
        char_options[${#option_strings[@]} + 1]=$char
        local option_string="$(( ${#option_strings[@]} + 1 ))/$char) $option"
    else
        local option_string="$(( ${#option_strings[@]} + 1 ))) $option"
    fi

    # Ellipsize any option strings that do not fit in the full terminal window
    if (( ${#option_string} >= terminal_width )); then
        local max_field_length=terminal_width
        option_string=$(ellipsize "$option_string")
    fi

    option_strings+=( "$option_string" )
}

# Calculate the index of the first option to appear on a given page
page_index() {
    local page=$1
    echo $(( ${page_indices[page - 1]} + terminal_lines - ${#page_selection_options[page - 1]} - header_line - 1 ))
}

# Prints the numbered options then prompts the user for input and validates against provided options
user_selection() {
    {
        local -a page_selection_options page_indices
        if [[ "$options_list_header" ]]; then
            local header_line=1
        else
            local header_line=0
        fi
        local page=0
        page_indices[0]=1
        # Build each page of options sequentially until no options remain
        while (( $(page_index $(( page + 1 ))) < ${#option_strings[@]} )); do
            if (( page == 0 )); then
                page_selection_options[0]=E # next
                page_selection_options[1]=V # previous
                page_indices[1]=$(page_index 1)
            elif (( page == 1 )); then
                page_selection_options[0]=EW # next last
                page_indices[1]=$(page_index 1)
                page_selection_options[1]=VE # previous next
                page_indices[2]=$(page_index 2)
                page_selection_options[2]=QV # first previous
            elif (( page == 2 )); then
                page_selection_options[1]=VEW # previous next last
                page_indices[2]=$(page_index 2)
                page_selection_options[2]=QVE # first previous next
                page_indices[3]=$(page_index 3)
                page_selection_options[3]=QV # first previous
            elif (( page > 2 )); then
                page_indices[page - 1]=$(page_index $(( page - 1 )))
                page_selection_options[page - 1]=QVEW # first previous next last
                page_indices[page]=$(page_index "$page")
                page_selection_options[page]=QVE # first previous next
                page_indices[page + 1]=$(page_index $(( page + 1 )))
                page_selection_options[page + 1]=QV # first previous
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

        # Loop for presenting options on the current page to the user and accepting input
        while true; do
            reset_screen
            if "$invalid_selection"; then
                warn "Invalid selection: '$selection'"
                read -rsp "Press enter to continue" _
                reset_screen
            fi
            invalid_selection=false
            if "$printinfo"; then
                print_clip_info
                echo
            fi
            if [[ "$options_list_header" ]]; then
                echo "$options_list_header"
            fi

            # Determine the first and last indices for options to display on the current page
            local start_index=${page_indices[page]}
            if [[ "${page_indices[page + 1]}" ]]; then
                local end_index=$(( ${page_indices[page + 1]} - 1 ))
            else
                local end_index=${#option_strings[@]}
            fi

            # Print all regular options from the start index to the end index, one option per line
            printf '%s\n' "${option_strings[@]:start_index - 1:end_index - start_index + 1}"

            unset page_selection_options_array
            local -a page_selection_options_array

            # Print the page selection options and generate an array of them to select from later
            current_page_selection_options=${page_selection_options[page]}
            for (( i=0; i < ${#current_page_selection_options}; i++ )); do
                option=${current_page_selection_options:$i:1}
                page_selection_options_array+=( "$option" )
                case "$option" in
                    Q)
                        echo "Q) First page" ;;
                    V)
                        echo "V) Previous page" ;;
                    E)
                        echo "E) Next page" ;;
                    W)
                        echo "W) Last page" ;;
                esac
            done

            local selection
            read -rp "$1" selection

            # Retry on empty selection
            if [[ -z "$selection" ]]; then
                invalid_selection=true
                continue
            fi

            # Loop through all presented options on this page to check if our selection matches one
            local option_index
            for option_index in $(seq "$start_index" "$end_index"); do
                local char_option=${char_options[option_index]}
                # If our selection was numeric and it matches the index of our current option,
                # then we have made a valid selection
                if [[ "$selection" =~ ^[0-9]+$ ]] && (( 10#$selection == option_index )); then
                    if [[ "$char_option" ]]; then
                        # If there's a corresponding character to this option, print that
                        selection=$char_option
                    fi
                    break 2
                # If we selected by character and it matches, we have made a valid selection
                elif [[ "${selection^^}" == "$char_option" ]]; then
                    break 2
                    selection=$char_option
                fi
            done

            # If no options matched our selection, selection may be a page selection option or an invalid selection
            if [[ "$selection" =~ ^[0-9]+$ ]]; then
                local page_selection_options_array_index=$(( 10#$selection - end_index - 1 ))
                if (( page_selection_options_array_index >= 0 )); then
                    selection=${page_selection_options_array[page_selection_options_array_index]}
                else
                    invalid_selection=true
                    continue
                fi
            elif [[ ! "$selection" =~ ^[${page_selection_options[page],,}${page_selection_options[page]^^}]$ ]]; then
                invalid_selection=true
                continue
            fi

            # If we selected a page selection option, go to the corresponding page
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
    } >&2
    # so that this function prints to terminal, even while using command substitution i.e. $(foo) or `foo`

    echo "$selection"
}

reset_screen() {
    head -c "$terminal_width" /dev/zero | tr '\0' '-' | xargs printf '\n%s'
    clear -x
}

# Provide the user with main options and take actions accordingly
select_program() {
    start_numbered_options_list
    # A test (original quality): Allow the user to listen to the clip in original quality
    numbered_options_list_option "A test (original quality)" "A"
    # B test (lossy): Allow the user to listen to the clip as compressed with the MP3 algorithm
    numbered_options_list_option "B test (${bitrate::-1} kbps lossy)" "B"
    # X test (unknown): Randomly and secretly presents the user with either original or MP3-compressed
    # and asks the user to identify which quality level they listened to
    # The x-test may only be attempted once per track
    if ! "$x_test_completed"; then
        numbered_options_list_option "X test (unknown)" "X"
    fi
    # Re-clip track: Allow the user to select or randomly generate timestamps
    # for a new clip from the current track
    numbered_options_list_option "Re-clip track" "R"
    # Moving to the next track is only allowed if the x-test hasn't been attempted or it's been completed
    if ! "$x_test_attempted" || "$x_test_completed"; then
        if [[ "$fully_random" =~ ^[Yy]$ ]]; then
            # Random next track: The next track is selected from the randomly sorted list generated at the start
            numbered_options_list_option "Random next track" "N"
        else
            # Find next track: User is presented with options to search for the artist, album, and track title
            numbered_options_list_option "Find next track" "F"
            numbered_options_list_option "Random next track" "N"
        fi
    fi
    # Change bitrate: Change the bitrate to which the MP3-encoded track is compressed to.
    # Selecting this option and subsequently altering the bitrate resets your score and track history
    numbered_options_list_option "Change bitrate" "C"
    # Only present these options if applicable
    if (( ${#results[@]} > 0 )); then
        # Print results: Print the current score and the results for each track played so far to the user
        numbered_options_list_option "Print results" "P"
        # Reset score: Erase the list of tracks played so far and the results for each, along with the total score
        numbered_options_list_option "Reset score" "T"
    fi
    # Save clip: If the user specified a directory to save clips to, allow them to save the current clip
    # The clip can be saved in either original or MP3-compressed quality at the current selected bitrate
    if [[ -d "$clips_dir" ]]; then
        numbered_options_list_option "Save clip" "S"
    fi
    # Quit: Exit the program
    numbered_options_list_option "Quit" "U"

    # Allow the user to make a selection from the above options
    program_selection=$(user_selection --printinfo "Selection: ")

    case "$program_selection" in
        A|a)
            play_clip "$original_clip" ;;
        B|b)
            play_clip "$lossy_clip" ;;
        X|x)
            # If the x-clip doesn't exist yet, allocate a temp file for it
            if [[ ! -f "$x_clip" ]]; then
                x_clip=$(mktemp --suffix=.wav)
            fi
            original_clip_modtime=$(stat -c "%Y" "$original_clip")
            x_clip_modtime=$(stat -c "%Y" "$x_clip")
            # If the x-clip is empty or if the original clip is newer, then we want to copy over a new x-clip
            if [[ ! -s "$x_clip" ]] || (( original_clip_modtime > x_clip_modtime )); then
                # x_clip_quality is randomly 0 or 1 with a 50% chance of each.
                if (( x_clip_quality )); then
                    # If 1, then the x-clip is original quality.
                    format=original
                    cp "$original_clip" "$x_clip"
                else
                    # Else if 0, then the x-clip is lossy/MP3-compressed
                    format=lossy
                    cp "$lossy_clip" "$x_clip"
                fi
            fi
            x_test
            ;;
        S|s)
            # Copy either A or B clip to a directory the user specified on cmdline or cfg file
            save_clip ;;
        P|p)
            # Print the current score and results to the terminal
            print_results ;;
        C|c)
            # Change the bitrate the MP3 file is encoded to
            select_mp3_bitrate
            create_clip
            ;;
        T|t)
            # Erase the results and reset the score to 0
            reset_score ;;
        N|n)
            # Go to the next track randomly
            # Record this track as having been skipped if the x-test was not attempted or finished
            if ! "$x_test_completed"; then
                add_result skipped
            fi
            next_track_is_random=true
            ;;
        F|f)
            # Search for the next track
            # Record this track as having been skipped if the x-test was not attempted or finished
            if ! "$x_test_completed"; then
                add_result skipped
            fi
            next_track_is_random=false
            ;;
        U|u)
            # Quit the application
            # Record the current track we were on when we quit, unless we already attempted the x-test
            if ! "$x_test_completed"; then
                add_result quit
            fi
            quit=true
            exit 0
            ;;
        R|r)
            cleanup
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

        if [[ "$timestamp_selection" =~ ^[Mm]$ ]]; then
            manual_timestamps
        elif [[ "$timestamp_selection" =~ ^[Rr]$ ]]; then
            random_timestamps
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
    local num_results=$(( ${#results[@]} + 1 ))
    local result=$1
    local guess=$2
    if [[ "$result" == skipped ]]; then
        skipped=$(( skipped + 1 ))
        local result_log="$num_results|$track_info|N/A|${YELLOW}${result^}${NOCOLOR}"
    elif [[ "$result" == quit ]]; then
        local result_log="$num_results|$track_info|N/A|${YELLOW}${result^}${NOCOLOR}"
    elif [[ "$guess" == forfeit ]]; then
        incorrect=$(( incorrect + 1 ))
        local result_log="$num_results|$track_info|${result^}|${RED}${guess^}${NOCOLOR}"
    elif [[ "$result" && "$guess" && "$result" == "$guess" ]]; then
        correct=$(( correct + 1 ))
        local result_log="$num_results|$track_info|${result^}|${GREEN}${guess^}${NOCOLOR}"
    elif [[ "$result" && "$guess" && "$result" != "$guess" ]]; then
        incorrect=$(( incorrect + 1 ))
        local result_log="$num_results|$track_info|${result^}|${RED}${guess^}${NOCOLOR}"
    else
        return 1
    fi
    results+=( "$result_log" )
}

# Choose the MP3 bitrate for the lossy clip
select_mp3_bitrate() {
    start_numbered_options_list "Select a bitrate for MP3 compression of the lossy file."
    local bitrate_option
    for bitrate_option in 32 64 96 112 128 256 320; do
        if [[ "$bitrate" && "$bitrate_option" == "${bitrate::-1}" ]]; then
            numbered_options_list_option "${GREEN}${bitrate_option} kbps${NOCOLOR}"
        else
            numbered_options_list_option "$bitrate_option kbps"
        fi
    done
    numbered_options_list_option "Custom" "C"
    local bitrate_selection
    bitrate_selection=$(user_selection "Selection: ")
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
            ;;
        *)
            errr "Input must be between 1 and ${#option_strings[@]}" ;;
    esac
    if [[ "$bitrate" != "$last_bitrate" ]]; then
        cleanup
        reset_score
        if [[ "$last_bitrate" ]]; then
            create_clip
        fi
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
        awk -v search="${search_string:-.*}" -F '/' 'BEGIN { IGNORECASE = 1 } $NF~search { printf "%s\n", NR - 1 }'
}

# Search for an artist with a given string
artist_search() {
    reset_screen
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
        numbered_options_list_option "$(basename "${all_artists[index]}")"
        matched_artists+=( "${all_artists[index]}" )
    done
    (( ${#matched_artists[@]} > 1 )) && numbered_options_list_option "Search albums of all above artists" "A"
    numbered_options_list_option "Random track from the above artists" "N"
    numbered_options_list_option "Retry search artist again" "R"

    local artist_selection
    artist_selection=$(user_selection "Select an artist to search their albums: ")
    if (( artist_selection == ${#option_strings[@]} )) || [[ "$artist_selection" =~ ^[Rr]$ ]]; then
        action=artist
    elif (( artist_selection == ${#option_strings[@]} - 1 )) || [[ "$artist_selection" =~ ^[Nn]$ ]]; then
        track=$(find "${matched_artists[@]}" -mindepth 2 -maxdepth 2 "${find_extensions[@]}" | sort -R | head -n 1)
        action=selected
    elif (( ${#matched_artists[@]} > 1 && artist_selection == ${#option_strings[@]} - 2 )) ||
        [[ "$artist_selection" =~ ^[Aa]$ ]]
    then
        action=album
    elif (( artist_selection <= ${#option_strings[@]} - 2 )); then
        matched_artists=( "${matched_artists[artist_selection - 1]}" ) # Search albums of a single artist
        action=album
    fi
}

# Search for an album with a given string
album_search() {
    reset_screen
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
        numbered_options_list_option "$(awk -F '/' '{ printf("%s - %s", $(NF-1), $NF) }' <<< "${albums[index]}")"
        matched_albums+=( "${albums[index]}" )
    done
    (( ${#matched_albums[@]} > 1 )) && numbered_options_list_option "Search tracks of above albums" "A"
    numbered_options_list_option "Random track from the above albums" "N"
    numbered_options_list_option "Search album again" "L"
    numbered_options_list_option "Search artist again" "R"

    local album_selection
    album_selection=$(user_selection "Select an album: ")
    if (( album_selection == ${#option_strings[@]} )) || [[ "$album_selection" =~ ^[Rr]$ ]]; then
        action=artist
    elif (( album_selection == ${#option_strings[@]} - 1 )) || [[ "$album_selection" =~ ^[Ll]$ ]]; then
        action=album
    elif (( album_selection == ${#option_strings[@]} - 2 )) || [[ "$album_selection" =~ ^[Nn]$ ]]; then
        track=$(find "${matched_albums[@]}" -mindepth 1 -maxdepth 1 "${find_extensions[@]}" | sort -R | head -n 1)
        action=selected
    elif (( ${#matched_albums[@]} > 1 && album_selection == ${#option_strings[@]} - 3 )) ||
        [[ "$album_selection" =~ ^[Aa]$ ]]
    then
        action=track
    elif (( album_selection <= ${#option_strings[@]} - 3 )); then
        matched_albums=( "${matched_albums[album_selection - 1]}" ) # Search one album
        action=track
    fi
}

# Search for a track with a given string
track_search() {
    reset_screen
    local -a tracks matched_tracks matched_track_indices
    local search_string track_selection
    local findopts=( -mindepth 1 -maxdepth 1 "${find_extensions[@]}" )
    start_numbered_options_list
    read -rp "Track title search string: " search_string
    if (( ${#matched_albums[@]} > 0 )); then
        mapfile -t tracks < <(find "${matched_albums[@]}" "${findopts[@]}" | sort -u)
    elif (( ${#matched_artists[@]} > 0 )); then
        mapfile -t tracks < <(find "${matched_artists[@]}" "${findopts[@]}" | sort -u)
    else
        tracks=( "${all_tracks[@]}" )
    fi

    mapfile -t matched_track_indices < <(utf8_array_search "${tracks[@]}")

    for index in "${matched_track_indices[@]}"; do
        track=${tracks[index]}
        numbered_options_list_option "$(awk -F '/' '{ printf("%s - %s - #%s", $(NF-2), $(NF-1), $NF) }' <<< "$track")"
        matched_tracks+=( "$track" )
    done
    numbered_options_list_option "Random track from above" "N"
    numbered_options_list_option "Search track again" "T"
    numbered_options_list_option "Search album again" "L"
    numbered_options_list_option "Search artist again" "R"

    track_selection=$(user_selection "Select a track: ")
    if (( track_selection == ${#option_strings[@]} )) || [[ "$track_selection" =~ ^[Rr]$ ]]; then
        action=artist
    elif (( track_selection == ${#option_strings[@]} - 1 )) || [[ "$track_selection" =~ ^[Ll]$ ]]; then
        action=album
    elif (( track_selection == ${#option_strings[@]} - 2 )) || [[ "$track_selection" =~ ^[Tt]$ ]]; then
        action=track
    elif (( track_selection == ${#option_strings[@]} - 3 )) || [[ "$track_selection" =~ ^[Nn]$ ]]; then
        track=$(IFS=$'\n'; sort -R <<< "${matched_tracks[*]}" | head -n 1)
        action=selected
    else
        track="${matched_tracks[track_selection - 1]}"
        generate_track_details
        action=selected
    fi
}

# Iterate through the pre-generated array of random indices
# and use each random index to select a track
random_next_track() {
    local random_track_index=${random_track_indices[current_track_index]}
    track=${all_tracks[random_track_index]}
    if (( ++current_track_index >= ${#all_tracks[@]} )); then
        current_track_index=0
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

    local max_field_length=$(( (terminal_width - 32)/3 ))
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

# Create an original-quality clip and a lossy clip from a given track at the given timestamps
# Obfuscate both original quality and lossy clips as .wav so it cannot easily be determinalined which is the X file
create_clip() {
    original_clip=$(mktemp --suffix=.wav)
    lossy_clip=$(mktemp --suffix=.wav)
    if [[ "${ffmpeg:?}" == *ffmpeg ]]; then
        local ffmpeg_track=$track
        local ffmpeg_original_clip=$original_clip
        local ffmpeg_lossy_clip=$lossy_clip
    else
        local ffmpeg_track=$(wslpath -w "$track")
        local ffmpeg_original_clip=$(wslpath -w "$original_clip")
        local ffmpeg_lossy_clip=$(wslpath -w "$lossy_clip")
    fi

    "${ffmpeg:?}" -nostdin -loglevel error -y -i "$ffmpeg_track" \
        -ss "$startsec" -t "$clip_duration" "$ffmpeg_original_clip" \
        -codec:a libmp3lame -ss "$startsec" -t "$clip_duration" -b:a "$bitrate" "$ffmpeg_lossy_clip" &
    create_clip_pid=$!
}

# Perform the following tasks in the background:
# SIGTERM the clip creation process if it exists
# Wait for the VLC child process to exit if it exists
# Wait for the clip creation process to terminate
# Remove all clips from the previous iteration
cleanup() {
    (
        kill "$create_clip_pid"
        while kill -0 "$vlc_pid"; do
            sleep 1
        done
        while kill -0 "$create_clip_pid"; do
            sleep 1
        done
        rm -f "$original_clip" "$lossy_clip" "$x_clip"
    ) &>/dev/null &
}

# Generate random timestamps to use for clipping
random_timestamps() {
    clip_duration=$default_duration
    local track_duration_int=${durations_map["$track"]}
    if (( track_duration_int < clip_duration)); then
        clip_duration=$track_duration_int
    fi
    local clip_start_max=$(( track_duration_int - clip_duration ))
    startsec=$(shuf -i 0-$clip_start_max -n 1 --random-source=/dev/urandom)
    endsec=$(( startsec + clip_duration ))
}

# Convert seconds to a string in the form of HH:MM:SS for HH > 00 or else MM:SS
seconds_to_timespec() {
    date -u --date=@"$1" +%H:%M:%S | sed -r 's/00:?([0-9]{2}:?[0-9]{2})/\1/g'
}

# Prompt the user for timestamps to use for clipping
manual_timestamps() {
    unset startsec endsec
    local startts endts
    while [[ -z "$startsec" ]]; do
        read -rp "Start timestamp: " startts
        if [[ -z "$startts" || "$startts" =~ ^[Rr]$ ]]; then
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
    play_clip "$x_clip"
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
        add_result "$format" forfeit
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
                local guess_format=original
            elif [[ "$guess" =~ ^[Ll]$ ]]; then
                local guess_format=lossy
            else
                errr "Unexpected condition occurred: guess='$guess'"
            fi
            start_numbered_options_list "You guessed $guess_format. Are you sure?"
            numbered_options_list_option "Yes" "Y"
            numbered_options_list_option "No" "N"
            local confirmation
            confirmation=$(user_selection --printinfo "Selection: ")
        done
        if [[ "$guess_format" == "$format" ]]; then
            echo "${GREEN}CORRECT!${NOCOLOR} The file was ${format^^} and your guess was ${guess_format^^}"
        else
            echo "${RED}INCORRECT.${NOCOLOR} The file was ${format^^} and your guess was ${guess_format^^}"
        fi
        add_result "$format" "$guess_format"
    fi
    accuracy=$(bc <<< "100 * $correct / ($correct + $incorrect)")
    x_test_completed=true
    echo "Your accuracy is now $accuracy% ($correct/$(( correct + incorrect )))"
    echo "$skipped tracks skipped"
    echo
    read -rsp "Press enter to continue:" _
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
}

# Print out details about the clip
print_clip_info() {
    local max_field_length=$(( terminal_width - $(printf "Artist: " | wc -c) ))
    local artist_el=$(ellipsize "${artists_map["$track"]}")
    echo "Artist: $artist_el"

    max_field_length=$(( terminal_width - $(printf "Album: " | wc -c) ))
    local album_el=$(ellipsize "${albums_map["$track"]}")
    echo "Album: $album_el"

    max_field_length=$(( terminal_width - $(printf "Title: " | wc -c) ))
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
        reset_screen
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
            printf '%s\n' "${results[@]}"
        } | column -ts '|'
        local tries=$(( correct + incorrect ))
        printf "%s%% accuracy, " "$accuracy"
        printf "%s correct out of " "$correct"
        printf "%s tries, " "$tries"
        printf "%s skipped\n" "$skipped"
        if [[ -z "$quit" ]]; then
            read -rsp "Press enter to continue:" _
        fi
    fi
}

exit_trap() {
    cleanup
    print_results
}

main "$@"
