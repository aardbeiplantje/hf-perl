#!/usr/bin/env perl

use strict; use warnings;
use File::Basename;
use File::Path qw(make_path);
use Cwd;

# Ensure required parameters are provided
die "Usage: $0 <repo_id|url> [filename] [target_dir]\n"
    unless @ARGV >= 1;

my $repo_id_or_url = $ARGV[0];
my $filename       = $ARGV[1];
my $target_dir     = $ARGV[2] // Cwd::cwd();

# Construct the Hugging Face standard resolve URL
my $url = $repo_id_or_url;
unless($url =~ m/^https:\/\//){
    $url = "https://huggingface.co/$repo_id_or_url/resolve/main/$filename";
}
my $b_fn = basename($url);
$url .= "?download=true";

# Ensure the target directory exists
unless (-d $target_dir) {
    make_path($target_dir)
        or die "Failed to create directory $target_dir: $!\n";
}

my $cdn_url;
my $hftoken = $ENV{HF_TOKEN};
my @curl_opts = (
    "--http1.1",
    "--connect-timeout",  "10",
    "--keepalive-time",    "5",
    "--tr-encoding",
    "-H", "'Transfer-Encoding: chunked'",
    "--retry", "2",
    "--retry-delay", "2",
    ($hftoken?(
        '-H', "'Authorization: Bearer $hftoken'"
    ):()),
);
my $dest_path = "$target_dir/$b_fn";

# Header check to get CDN URL
{
    my @head_cmd = (
        'curl',
        '-qsSI',
        @curl_opts,
        $url,
    );
    my $headers_cmd = join(" ", @head_cmd);
    my $headers = `$headers_cmd`;
    if ($! or $?){
        die "problem running curl headers check: $!\n" if $!;
        my $e_c = $? >> 8;
        my $e_s = $? & 127;
        die "curl headers check failed with exit=$e_c,signal=$e_s\n";
    }
    chomp($headers);
    ($cdn_url) = ($headers =~ /^Location:\s*(https?:\/\/[^\r\n]+)/im);
    die "No CDN url when checking $url\n" unless length($cdn_url//"");
}

# Download loop with retry and partial transfer detection  
my $hdr_log = "$dest_path.hdr.tmp";
my $max_attempts = 5;
my $attempts_left = $max_attempts;
my $prev_size = 0;

while ($attempts_left > 0) {
    my @cmd = (
        'curl',
        '-qS',
        '--progress-bar',
        "--http1.1",
        "--connect-timeout", "10",
        "--keepalive-time", "5",
        "--tr-encoding",
        "-H", "'Transfer-Encoding: chunked'",
        "--retry", "2",
        "--retry-delay", "2",
        "--dump-header", $hdr_log,
        ($hftoken ? ('-H', "'Authorization: Bearer $hftoken'") : ()),
        '-C', '-',  # resume partial downloads automatically  
        '-o', $dest_path,
        $cdn_url,
    );

    print "Downloading $b_fn from $repo_id_or_url to '$dest_path'\n";
    my $r = system(@cmd);

    if($r == -1){
        die "problem running curl: $!\n";
    } elsif($r != 0) {
        my $e_c = $? >> 8;
        my $e_s = $? & 127;

        # Check if we should retry based on error type and file state  
        if((-f $dest_path) && ($e_c != 23)) {
            # Non-fatal error or transient issue with partial download
            my $file_size = -s $dest_path;
            
            # Reset attempts if file grew (progress is being made)
            if($file_size > $prev_size) {
                print "Download progress detected ($prev_size -> $file_size bytes), resetting retry counter\n";
                $attempts_left = $max_attempts;
            } else {
                $attempts_left--;
            }
            $prev_size = $file_size;
            
            printf("Retrying download (%d attempts remaining)...\n", $attempts_left);
            next unless $attempts_left > 0;
        } elsif($e_c == 23) {
            # Server error (4xx/5xx), not worth retrying without changes
            unlink $hdr_log if -f $hdr_log;
            die "curl failed with server error exit=$e_c,signal=$e_s\n";
        } else {
            unlink $hdr_log if -f $hdr_log;
            die "curl failed with exit=$e_c,signal=$e_s\n";
        }
    }

    # Validate the download via headers log file
    if(-f $hdr_log) {
        open(my $hf, '<', $hdr_log);
        my %headers;
        while(<$hf>) {
            $headers{cl} = int($1) if /^Content-Length:\s*(\d+)/i;
            $headers{ct} = $1 if /^Content-Type:\s*([^\s]+)/i;
        }
        close($hf);

        # Verify file is complete by comparing Content-Length to actual size  
        if(exists $headers{cl}) {
            my $expected = $headers{cl};
            my $actual = -s $dest_path;

            if($actual < $expected) {
                # Check if this is new progress vs previous attempt size  
                if($actual > $prev_size) {
                    print "Download progress detected ($prev_size -> $actual bytes), resetting retry counter\n";
                    $attempts_left = $max_attempts;
                } else {
                    $attempts_left--;
                }
                $prev_size = $actual;
                
                printf("Warning: Incomplete download ($actual/$expected bytes), %d attempts remaining\n", $attempts_left);
                next unless $attempts_left > 0;
            } elsif($actual > $expected) {
                print "Warning: File larger than expected ($actual/$expected bytes)\n";
                # Don't fail on this, but don't retry either  
            } else {
                print "Download complete.\n";
                unlink $hdr_log if -f $hdr_log;
                last;  # Success! Exit the loop  
            }
        } else {
            # No Content-Length header (chunked transfer), assume success on exit code 0  
            print "Download complete (no content-length header).\n";
            unlink $hdr_log if -f $hdr_log;
            last;
        }
    } else {
        die "curl reported success but output file '$dest_path' does not exist\n" 
            unless $attempts_left == 1;
    }
}

