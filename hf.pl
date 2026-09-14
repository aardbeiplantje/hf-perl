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
my $target_dir     = $ARGV[2] // $ENV{MODELS_DIR} // Cwd::cwd();

# Construct the Hugging Face standard resolve URL
my $url = $repo_id_or_url;
unless($url =~ m/^https:\/\//){
    $url = "https://huggingface.co/$repo_id_or_url/resolve/main/$filename";
}
my $b_fn = basename($url);
$url .= "?download=true";

# Ensure the target directory exists
unless(-d $target_dir){
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
    "--retry", "2",
    "--retry-delay", "2",
    ($hftoken?(
        '-H', "'Authorization: Bearer $hftoken'"
    ):()),
    "-H", "'Transfer-Encoding: chunked'",
);
my $dest_path = "$target_dir/$b_fn";

# Header check to get CDN URL, ETag and size  
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

    # Extract Location (CDN URL)  
    ($cdn_url) = ($headers =~ /^Location:\s*(https?:\/\/[^\r\n]+)/im);
    die "No CDN url when checking $url\n" unless length($cdn_url//"");
}

# Validate against CDN URL to ensure consistency  
my $cdn_etag;
my $cdn_size;
{
    my @cdn_head_cmd = (
        'curl',
        '-qsSLI',
        "--http1.1",
        "--connect-timeout", "10",
        "--keepalive-time", "5", 
        "-H", "'Transfer-Encoding: chunked'",
        ($hftoken?(
            '-H', "'Authorization: Bearer $hftoken'"
        ):()),
        $url,
    );
    my $cdn_headers = join(" ", @cdn_head_cmd);
    my $response_headers = `$cdn_headers`;
    if($! or $?){
        print "Warning: could not validate CDN response for ETag/size check\n";
    } else {
        chomp($response_headers);
        while ($response_headers =~ /^(\S+):\s+(.+)$/gm) {
            my $name = lc($1);
            my $value = $2;
            chop($value);
            # always pick the last one, we use -L to curl to follow, and the last
            # one is the cdn real download link
            $cdn_etag = $value if $name eq "etag";
            $cdn_size = $value if $name eq 'content-length';
        }
    }
}
$cdn_etag =~ s/"//g;
print "Etag: $cdn_etag, size: $cdn_size\n";

# Download loop with retry and partial transfer detection  
my $hdr_log = "$dest_path.hdr.tmp";
my $max_attempts = 5;
my $attempts_left = $max_attempts;
my $prev_size = 0;

print "Downloading $b_fn from $repo_id_or_url to '$dest_path'\n";
while ($attempts_left > 0){
    last if ((-s $dest_path)//0) == $cdn_size;
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
        ($hftoken?(
            '-H', "'Authorization: Bearer $hftoken'"
        ):()),
        '-C', '-',
        '-o', $dest_path,
        $cdn_url,
    );

    print "Downloading (attempt left $attempts_left)\n";
    my $r = system(@cmd);
    if($r == -1){
        die "problem running curl: $!\n";
    } elsif($r != 0) {
        my $e_c = $? >> 8;
        my $e_s = $? & 127;

        # Check if we should retry based on error type and file state  
        if($e_s == 2) {
            # Ctrl-C pressed, exit cleanly
            print "\nDownload interrupted by user.\n";
            last;
        } elsif((-f $dest_path) && ($e_c != 23)) {
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

            print "Retrying download ($attempts_left attempts remaining)...\n";
            next unless $attempts_left > 0;
        } elsif($e_c == 23) {
            # Server error (4xx/5xx), not worth retrying without changes
            die "curl failed with server error exit=$e_c,signal=$e_s\n";
        } else {
            die "curl failed with exit=$e_c,signal=$e_s\n";
        }
    }
}

print "Download finished $dest_path\n";

END {
    unlink $hdr_log if $hdr_log and -f $hdr_log;
}
