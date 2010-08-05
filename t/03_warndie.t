use strict;
use Test::More tests => 2;

use Log::Dispatch::Config::Watcher;
use Log::Dispatch::Configurator::YAML;
use IO::Scalar;

my $config = Log::Dispatch::Configurator::YAML->new('t/log_warndie.yaml');
Log::Dispatch::Config::Watcher->configure($config);

my $err;
{
    tie *STDERR, 'IO::Scalar', \$err;
    my $disp = Log::Dispatch::Config::Watcher->instance;

    warn 'warning';
    like $err, qr{^\[error\] warning}, 'warn and warn level';
    undef $err;

    eval { die 'die'; };
    like $err, qr{^\[alert\] die}, 'die and die level';
    undef $err;
}

