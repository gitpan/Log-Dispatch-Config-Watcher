use strict;
use Test::More tests => 2;

use Log::Dispatch::Config::Watcher;
use Log::Dispatch::Configurator::YAML;
use IO::Scalar;

my $config = Log::Dispatch::Configurator::YAML->new('t/log_extension_fmt.yaml');
Log::Dispatch::Config::Watcher->configure($config);

my $err;
{
    tie *STDERR, 'IO::Scalar', \$err;
    my $disp = Log::Dispatch::Config::Watcher->instance;

    $disp->debug('debug');
    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime;
    $year += 1900;
    $mon = sprintf '%02d', $mon + 1;
    $mday = sprintf '%02d', $mday;
    is $err, "$year-$mon-$mday", '%D{%Y-%m-%d} format';
    undef $err;

    test1();
    like $err, qr{^\[info\][ ]START:TEST[ ]TASK\[info\][ ]END:TEST[ ]TASK\(\d{2}:\d{2}:\d{2}.\d+\)$}xms, '%j %t format';
    undef $err;
}

sub test1 {} 
