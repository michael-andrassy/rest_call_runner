#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP;
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol 'gensym';
use POSIX qw(strftime);

################################################################################
# print_usage
#   Prints usage instructions for this script. No file/network IO, no side effects
#   beyond printing to STDOUT.
################################################################################
sub print_usage {
    print <<USAGE;
Usage:
  $0 [--dry-run] [--continue-on-error=(yes|no)] <config-file> <workdir>

Description:
  - config-file: Path to the JSON configuration file.
  - workdir:     Path to the output directory, or "__timestamp" to create a
                 timestamped directory ("work_<ISO8601>").

Optional switches:
  --dry-run                If set, do not actually perform the curl calls;
                           simulate them instead, returning HTTP status 999.
  --continue-on-error=yes  (default) continue executing calls even if one fails.
  --continue-on-error=no   stop execution if a call fails (non-2xx/999).

If mandatory parameters are missing, this usage will be shown.
USAGE
}

################################################################################
# main
#   Entry point; parses arguments, loads config, sets up workdir, obtains token,
#   executes configured REST calls in order.
################################################################################
sub main {
    my $dry_run          = 0;   # Default: false
    my $continue_on_error = 1;  # Default: yes (true)
    my $config_file;
    my $workdir;

    # -------------------------------------------------------------------------
    # Parse command-line arguments
    # -------------------------------------------------------------------------
    while (my $arg = shift @ARGV) {
        if ($arg eq '--dry-run') {
            $dry_run = 1;
        } elsif ($arg =~ /^--continue-on-error=(.*)$/) {
            my $val = lc($1);
            if ($val eq 'no') {
                $continue_on_error = 0;
            } else {
                $continue_on_error = 1; # default
            }
        } else {
            # If it's not a recognized switch, it must be either config-file or workdir
            if (!defined $config_file) {
                $config_file = $arg;
            } elsif (!defined $workdir) {
                $workdir = $arg;
            } else {
                print_usage();
                exit 1;
            }
        }
    }

    # -------------------------------------------------------------------------
    # Check mandatory params
    # -------------------------------------------------------------------------
    unless (defined $config_file && defined $workdir) {
        print_usage();
        exit 1;
    }

    # -------------------------------------------------------------------------
    # Resolve "__timestamp" in workdir if necessary
    # -------------------------------------------------------------------------
    if ($workdir eq '__timestamp') {
        my $ts = strftime("%Y%m%dT%H%M%S", localtime);
        $workdir = "work_$ts";
    }

    # -------------------------------------------------------------------------
    # Load configuration file (JSON). Abort if unsuccessful.
    # -------------------------------------------------------------------------
    my $config = load_config($config_file);

    # -------------------------------------------------------------------------
    # Check if workdir exists. Abort if it does. Otherwise, create it.
    # -------------------------------------------------------------------------
    if (-e $workdir) {
        die "Workdir '$workdir' already exists. Aborting.\n";
    }
    make_path($workdir) or die "Failed to create workdir '$workdir': $!\n";

    # -------------------------------------------------------------------------
    # Prepare global log file for all curl calls
    # -------------------------------------------------------------------------
    my $global_curl_log = File::Spec->catfile($workdir, 'all_curl_calls.txt');
    open my $GLOBAL_CURL_LOG_FH, '>', $global_curl_log
        or die "Cannot open global curl log '$global_curl_log': $!\n";
    close $GLOBAL_CURL_LOG_FH; # We'll append in subroutines

    # -------------------------------------------------------------------------
    # Load replacement variables from config (if any)
    # -------------------------------------------------------------------------
    my %replacement_vars = ();
    if (exists $config->{variables} && ref $config->{variables} eq 'HASH') {
        while (my ($varname, $value) = each %{ $config->{variables} }) {
            $replacement_vars{$varname} = $value;
        }
    }

    # -------------------------------------------------------------------------
    # If there is a token_fetch_url, retrieve the bearer token (unless in dry-run).
    # -------------------------------------------------------------------------
    my $bearer_token = '';
    if (exists $config->{token_fetch_url} && $config->{token_fetch_url}) {
        $bearer_token = fetch_bearer_token(
            $config->{token_fetch_url},
            $config->{token_extraction_command},
            $workdir,
            $dry_run
        );
    }

    # -------------------------------------------------------------------------
    # Execute the sequence of REST calls (if base_url + calls present)
    # -------------------------------------------------------------------------
    if (exists $config->{base_url} && exists $config->{calls}) {
        my $base_url = $config->{base_url};
        my $calls    = $config->{calls};

        if (ref $calls eq 'ARRAY') {
            CALL_LOOP: foreach my $call_conf (@$calls) {
                my ($ok, $http_status, $updated_vars_ref) = execute_rest_call(
                    $call_conf,
                    $base_url,
                    $workdir,
                    $dry_run,
                    $bearer_token,
                    \%replacement_vars
                );

                # Merge updates from call param-extraction into our global %replacement_vars
                %replacement_vars = %$updated_vars_ref if $updated_vars_ref;

                # Evaluate success/fail and handle continue_on_error
                if (!$ok) {
                    print STDERR "Call '$call_conf->{identifier}' failed with status $http_status.\n";
                    if (!$continue_on_error) {
                        print STDERR "Stopping execution due to --continue-on-error=no.\n";
                        last CALL_LOOP;
                    }
                } else {
                    print "Call '$call_conf->{identifier}' completed with status $http_status.\n";
                }
            }
        }
    }

    print "\nScript completed.\n";
}

################################################################################
# load_config
#   Parameters:
#       $file - the path to the JSON config file
#   Returns:
#       A Perl data structure (hashref) containing the parsed config.
#   File IO: Reads from $file.
#   Network IO: none.
################################################################################
sub load_config {
    my ($file) = @_;
    open my $fh, '<', $file or die "Cannot open configuration file '$file': $!\n";
    local $/ = undef;
    my $json_text = <$fh>;
    close $fh;

    # decode_json will throw an error if the JSON is invalid
    my $config = decode_json($json_text);

    return $config;
}

################################################################################
# fetch_bearer_token
#   Parameters:
#       $token_fetch_url       - The GET url for fetching token (may contain env placeholders: ${NAME})
#       $token_extraction_cmd  - The command line to extract the token from JSON (optional)
#       $workdir               - For logging
#       $dry_run               - If true, we skip actual call
#   Returns:
#       The extracted bearer token as a string.
#   File IO: Writes to global curl log, writes token fetch response to x_token_fetch.json
#   Network IO: Performs one GET call to retrieve token (unless dry-run).
#   Potentially modifies program flow by calling 'die' if token fetch fails.
################################################################################
sub fetch_bearer_token {
    my ($token_fetch_url, $token_extraction_cmd, $workdir, $dry_run) = @_;

    print "Fetching bearer token...\n";

    my $method = "GET";
    my $tmp_body_file = ''; # No body for GET
    my $token_fetch_id = "token_fetch"; # used for logging
    my ($ok, $http_status, $response_body) =
        do_curl($method, $token_fetch_url, $tmp_body_file, $workdir, $token_fetch_id, "", $dry_run, []);

    if (!$ok && !$dry_run) {
        die "Failed to fetch bearer token (HTTP status: $http_status). Aborting.\n";
    }

    # If dry-run, we pretend success, returning a dummy token
    if ($dry_run) {
        print "Dry-run active. Returning 'DRYRUN_BEARER_TOKEN'...\n";
        return "DRYRUN_BEARER_TOKEN";
    }

    print "Raw bearer token acquired: $response_body\n";

    # If we are here, we presumably have a 2xx success. Use the extraction command if given.
    my $bearer_token = '';
    if ($token_extraction_cmd) {
        # Run the user-defined command with the response as STDIN
        $bearer_token = run_command_with_input($token_extraction_cmd, $response_body);
        $bearer_token =~ s/\s+$//;  # Trim trailing whitespace
        $bearer_token =~ s/^\s+//;
    } else {
        die "No 'token_extraction_command' specified in config, cannot extract token.\n";
    }

    if (!$bearer_token) {
        die "Bearer token extraction yielded empty result. Aborting.\n";
    }

    print "Bearer token acquired: $bearer_token\n";
    return $bearer_token;
}

################################################################################
# execute_rest_call
#   Parameters:
#       $call_conf       - Hashref from config describing the call
#       $base_url        - The base URL prefix for calls
#       $workdir         - Output directory
#       $dry_run         - Whether we skip actual curl
#       $bearer_token    - The token used for Authorization
#       $replacement_vars_ref - Hashref of replacement variables
#   Returns:
#       ( $ok, $http_status, $updated_vars_ref )
#         where $ok is boolean success, $http_status is the numeric code,
#         and $updated_vars_ref is the updated replacement vars (with any new
#         extractions).
#   File IO: writes to x_*, p_*, l_* files. Possibly reads a request body file.
#   Network IO: does the actual curl call (unless dry-run).
#   Potentially modifies replacement vars (param-extraction).
################################################################################
sub execute_rest_call {
    my ($call_conf, $base_url, $workdir, $dry_run, $bearer_token, $replacement_vars_ref) = @_;

    my %vars_copy = %{$replacement_vars_ref};  # local working copy

    # Extract call config
    my $call_id      = $call_conf->{identifier} // 'unknown_call';
    my $method       = $call_conf->{rest_method} // 'GET';
    my $url_snippet  = $call_conf->{url} // '';
    my $body_file    = $call_conf->{body_file}; # optional
    my $extracts     = $call_conf->{param_extractions} // [];
    my $obfuscations = $call_conf->{obfuscation_rules} // [];
    my $headers      = $call_conf->{headers};   # arrayref or undef

    unless ($call_id =~ /^[a-zA-Z0-9_-]+$/) {
        die "Invalid call identifier '$call_id'. Must be [a-zA-Z0-9_-]+.\n";
    }
    unless ($method =~ /^(GET|POST|PUT)$/) {
        die "Invalid rest_method '$method' for call '$call_id'. Allowed: GET, POST, PUT.\n";
    }

    # Apply replacements to $url_snippet
    my $final_url_snippet = apply_replacements($url_snippet, \%vars_copy);
    my $final_url = $base_url . apply_replacements($final_url_snippet, \%vars_copy);

    # Prepare request-body if applicable
    my $request_body = '';
    my $request_body_file_path = '';
    if (defined $body_file && length $body_file) {
        if ($body_file =~ /^W:(.*)/) {
            # interpret as a file in the workdir
            my $relpath = $1;
            $request_body_file_path = File::Spec->catfile($workdir, $relpath);
        } else {
            # interpret as relative or absolute path on the filesystem
            $request_body_file_path = $body_file;
        }

        # Load the request body from file if it exists
        if (-f $request_body_file_path) {
            $request_body = read_file($request_body_file_path);
            # Apply replacements
            $request_body = apply_replacements($request_body, \%vars_copy);
        } else {
            print STDERR "Warning: request body file '$request_body_file_path' not found for call '$call_id'.\n";
        }
    }

    # Write "private" version of the request body to x_(call_id)_request.json
    my $x_req_file = File::Spec->catfile($workdir, "x_${call_id}_request.json");
    if ($request_body) {
        write_file($x_req_file, $request_body);
    }

    # Actually do the call
    # Pass the headers array along, so do_curl can handle them
    my ($ok, $http_status, $response_body) =
        do_curl($method, $final_url, $x_req_file, $workdir, $call_id, $bearer_token, $dry_run, $headers);

    # Write private version of the response if success
    my $x_resp_file = File::Spec->catfile($workdir, "x_${call_id}_response.json");
    if ($ok && !$dry_run) {
        if ($http_status eq '999') {
            $response_body = "DRY-RUN-RESPONSE";
        }
        write_file($x_resp_file, $response_body);
    }

    # Create the l_(call_id)_(http_status).txt log file
    my $l_file = File::Spec->catfile($workdir, "l_${call_id}_${http_status}.txt");
    if (!$dry_run) {
        my $before_vars_str = join("\n", map { "$_ = $vars_copy{$_}" } sort keys %vars_copy);
        my $content = <<INFO;
--- Replacement Vars (Before) ---
$before_vars_str

--- Request Body ---
$request_body

--- Final URL ---
$final_url

--- HTTP Status ---
$http_status

--- Response Body ---
$response_body

--- Replacement Vars (After) ---
INFO
        write_file($l_file, $content);
    }

    # Perform param-extractions if success
    if ($ok && $extracts && ref $extracts eq 'ARRAY') {
        foreach my $pe (@$extracts) {
            my $var_name = $pe->{var_name} // '';
            my $cmd_line = $pe->{cmd} // '';
            next unless $var_name && $cmd_line;

            # Apply replacements to the command line
            my $final_cmd_line = apply_replacements($cmd_line, \%vars_copy);

            # Run it with the response body as stdin
            my $extracted_value = run_command_with_input($final_cmd_line, $response_body);
            chomp $extracted_value;
            $vars_copy{$var_name} = $extracted_value;
        }
    }

    # Update "Replacement Vars (After)" portion
    if (!$dry_run) {
        my $after_vars_str = join("\n", map { "$_ = $vars_copy{$_}" } sort keys %vars_copy);
        open my $LFH, '>>', $l_file or die "Cannot append to '$l_file': $!";
        print $LFH $after_vars_str, "\n";
        close $LFH;
    }

    # Perform obfuscation if success
    if ($ok && !$dry_run) {
        # 1) Request
        if ($request_body) {
            my $p_req_file = File::Spec->catfile($workdir, "p_${call_id}_request.json");
            do_obfuscation($x_req_file, $p_req_file, $obfuscations, \%vars_copy);
        }
        # 2) Response
        my $p_resp_file = File::Spec->catfile($workdir, "p_${call_id}_response.json");
        if ($response_body) {
            do_obfuscation($x_resp_file, $p_resp_file, $obfuscations, \%vars_copy);
        }
    }

    # Return success/fail plus updated vars
    return ($ok, $http_status, \%vars_copy);
}

################################################################################
# apply_replacements
#   Parameters:
#       $text                 - string on which to perform replacements
#       $replacement_vars_ref - hashref (key => value)
#   Returns:
#       The updated string after substituting occurrences of each key with
#       the associated value.
#   No file or network IO. Pure string manipulation.
################################################################################
sub apply_replacements {
    my ($text, $replacement_vars_ref) = @_;
    my $new_text = $text;

    # For each replacement var, do a naive global search/replace
    foreach my $var_name (sort { length($b) <=> length($a) } keys %{$replacement_vars_ref}) {
        my $value = $replacement_vars_ref->{$var_name};
        my $safe_var_name = quotemeta($var_name);
        $new_text =~ s/$safe_var_name/$value/g;
    }

    return $new_text;
}

################################################################################
# read_file
#   Parameters:
#       $filepath - path to a file to be read
#   Returns:
#       The entire content of the file as a single scalar (string).
#   File IO: reads from $filepath.
################################################################################
sub read_file {
    my ($filepath) = @_;
    open my $fh, '<', $filepath or die "Cannot read file '$filepath': $!\n";
    local $/ = undef;
    my $content = <$fh>;
    close $fh;
    return $content;
}

################################################################################
# write_file
#   Parameters:
#       $filepath - path to a file to write
#       $content  - string content to be written
#   Returns:
#       void
#   File IO: writes content to $filepath (overwrites).
################################################################################
sub write_file {
    my ($filepath, $content) = @_;
    open my $fh, '>', $filepath or die "Cannot write to file '$filepath': $!\n";
    print $fh $content;
    close $fh;
}

################################################################################
# run_command_with_input
#   Parameters:
#       $command - shell command (may contain pipes) to run
#       $input   - string to be fed to the command's stdin
#   Returns:
#       The command's stdout as a string.
#   File IO: none directly (pipes used), no direct network calls here.
#   Potential side effect: if the command itself does external actions.
################################################################################
sub run_command_with_input {
    my ($command, $input) = @_;

    my $stderr = gensym;
    my $pid = open3(my $cmd_in, my $cmd_out, $stderr, $command)
        or die "Can't execute command '$command': $!\n";

    # Send input
    print $cmd_in $input;
    close $cmd_in;

    # Read output
    my $output = do { local $/; <$cmd_out> };
    close $cmd_out;

    # Read any error message
    my $error_msg = do { local $/; <$stderr> } // '';
    close $stderr;

    waitpid($pid, 0);
    my $exit_code = $? >> 8;
    if ($exit_code != 0) {
        print STDERR "Command [$command] failed with exit code $exit_code.\n";
        print STDERR "stderr: $error_msg\n" if $error_msg;
    }

    return $output // '';
}

################################################################################
# do_obfuscation
#   Parameters:
#       $infile              - source file path for private content
#       $outfile             - destination file path for public content
#       $obfuscation_rules   - arrayref of rules, each is { cmd => '...' }
#       $replacement_vars_ref - for substituting variables in the rule commands
#   Returns:
#       void
#   File IO: reads $infile, writes $outfile, possibly uses temp strings.
#   No direct network IO here.
################################################################################
sub do_obfuscation {
    my ($infile, $outfile, $obfuscation_rules, $replacement_vars_ref) = @_;

    my $temp_input = read_file($infile);

    if ($obfuscation_rules) {

        foreach my $rule (@$obfuscation_rules) {
            my $cmd_line = $rule->{cmd} // '';
            next unless $cmd_line;

            # Example commented-out command to match "123" and replace with "abc":
            #   # sed 's/123/abc/g'
            #
            $cmd_line = apply_replacements($cmd_line, $replacement_vars_ref);

            my $transformed = run_command_with_input($cmd_line, $temp_input);
            $temp_input = $transformed;
        }

    } 
    
    write_file($outfile, $temp_input);

}

################################################################################
# do_curl
#   Parameters:
#       $method        - GET/POST/PUT
#       $url           - final URL (may contain env placeholders like ${SECRET})
#       $body_file     - if non-empty, pass as data to curl
#       $workdir       - to locate the global log
#       $call_id       - used for logging
#       $bearer_token  - if non-empty, used for Authorization: Bearer
#       $dry_run       - skip real network call if true
#       $headers       - arrayref of additional header lines
#   Returns:
#       ( $ok, $http_status, $response_body )
#         $ok is boolean indicating if $http_status is 2xx or (in dry-run) 999
#   File IO: appends to the global 'all_curl_calls.txt'
#   Network IO: performs the curl call if not dry-run
#   Potential side effect: logs command line, influences next steps if call fails.
################################################################################
sub do_curl {
    my ($method, $url, $body_file, $workdir, $call_id, $bearer_token, $dry_run, $headers) = @_;

    my $global_curl_log = File::Spec->catfile($workdir, 'all_curl_calls.txt');

    $ENV{"MY_BEARER_TOKEN"} = $bearer_token;

    # Basic curl arguments
    my $method_arg = "-X $method";
    my $data_arg   = ($body_file && -f $body_file) ? qq{--data-binary \@$body_file} : '';
    my $auth_arg   = $bearer_token ? q{-H "Authorization: Bearer $MY_BEARER_TOKEN"} : '';
    my $silent_arg = '-sS';  # silent mode, show errors

    # Prepare additional headers
    my @extra_headers_args;
    if ($headers && ref $headers eq 'ARRAY') {
        foreach my $hdr (@$headers) {
            # Each header might contain references to environment variables or
            # might be literal. We do NOT expand environment placeholders
            # ourselves but do want them in the final command line so the shell
            # can expand them if needed. We also do not forcibly prefix them
            # with "CALL_VAR_", but if you used replacement variables in the
            # config, those are handled earlier in apply_replacements. 
            # We'll simply pass them as -H "...."
            push @extra_headers_args, qq{-H "$hdr"};
        }
    }

    # Build the final derived command line
    my $headers_str = join(" ", @extra_headers_args);
    my $curl_cmd = qq{curl $silent_arg $method_arg $auth_arg $headers_str "$url" $data_arg -w "%{http_code}"};

    # Log the derived curl command line (not expanding environment placeholders)
    {
        open my $GL, '>>', $global_curl_log or die "Cannot append to '$global_curl_log': $!\n";
        print $GL $curl_cmd, "\n\n";
        close $GL;
    }

    # If dry-run, skip actual call and pretend success
    if ($dry_run) {
        return (1, '999', 'DRY-RUN-RESPONSE');
    }

    # Perform the actual curl
    my $output = qx{$curl_cmd};
    my $exit_code = $? >> 8;

    if ($exit_code != 0) {
        # curl technical failure
        return (0, "curl-fail-$exit_code", "");
    }

    # Separate the appended HTTP code from the body
    my $http_code = substr($output, -3);
    my $response_body = substr($output, 0, length($output) - 3);

    my $ok = 0;
    if ($http_code =~ /^2\d\d$/) {
        $ok = 1;
    }
    return ($ok, $http_code, $response_body);
}

# ------------------------------------------------------------------------------
# Actually run the main routine
# ------------------------------------------------------------------------------
main();

__END__

=head1 NAME

rest_sequence_script.pl - A Perl script to execute a sequence of REST calls
as specified in a JSON configuration, with optional additional headers, logging
requests/responses, performing parameter extractions, optional obfuscation, etc.

=head1 DESCRIPTION

This script demonstrates a reference implementation of the requirements:

=over

=item * Loads a JSON configuration describing how to fetch a bearer token,  
a set of replacement variables, a base URL, and a list of REST calls.  

=item * Supports additional per-call HTTP headers via a new "headers" attribute  
in each call's config.  

=item * Optionally fetches a bearer token at the start and uses a provided command  
(e.g., C<jq>) to extract the token from the response JSON.  

=item * Executes the calls in order, each with optional request body, saving  
private and public (obfuscated) request/response copies.  

=item * Allows for param-extraction from responses, which updates a set of  
in-memory variables used for subsequent calls.  

=item * Logs all derived curl calls to a single log file (C<all_curl_calls.txt>)  
for user inspection.  

=item * Supports a dry-run mode (does not perform real network calls).  

=item * Allows continuing on error or aborting on first error.  

=back

=head1 SECURITY CONSIDERATIONS

=over

=item * The script does not expand environment variables that appear as C<${VAR}> in the URL,  
body, or header lines. It leaves them for the shell when executing curl.  

=item * This approach avoids inadvertently leaking secrets that are only present  
in container environment variables.  

=item * Sensitive data in the response can be removed or masked by user-defined  
obfuscation rules in the config (e.g., C<sed>, C<jq> transformations).  

=back

=head1 LIMITATIONS

=over

=item * Shell meta-characters or malicious content in the user-supplied commands  
could cause unexpected behaviors.  

=item * Obfuscation commands are run in sequence and may conflict if they assume  
exclusive ownership of the data.  

=back

=head1 AUTHOR

(Your organization / yourself)

=cut
