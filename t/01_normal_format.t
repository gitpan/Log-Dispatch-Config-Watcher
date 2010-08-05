use strict;
use Test::More tests => 4;

use Log::Dispatch::Config::Watcher;
use FileHandle;
use IO::Scalar;
use File::Spec;

sub slurp {
    my $fh = FileHandle->new(shift) or die $!;
    local $/;
    return $fh->getline;
}

my $log;
BEGIN { $log = 't/log.out'; unlink $log if -e $log }
END   { unlink $log if -e $log }

Log::Dispatch::Config::Watcher->configure('t/log_normal_fmt.cfg');

my $err;
{
    tie *STDERR, 'IO::Scalar', \$err;
    my $disp = Log::Dispatch::Config::Watcher->instance;
    $disp->debug('debug');
    $disp->alert('alert');
}

my $filename = File::Spec->catfile('t', '01_normal_format.t');
my $file = slurp $log;
like $file, qr(debug at \Q$filename\E), '%F format(debug)';
like $file, qr(alert at \Q$filename\E), '%F format(alert)';

ok $err !~ qr/debug/, '%m %% format(debug)';
is $err, "alert %", '%m %% format(alert)';


