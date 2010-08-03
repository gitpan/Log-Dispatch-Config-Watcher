package Log::Dispatch::Config::Watcher;
use strict;
use warnings;
our $VERSION = '0.01_2';

use utf8;
use DateTime;
use DateTime::HiRes;
use DateTime::Format::Strptime;
use DateTime::Duration;
use DateTime::Format::Duration;
use Hook::LexWrap ();
use Log::Dispatch::Config;
use base qw(Log::Dispatch::Config);

# backup existing die/warn handlers
my $WARN;
my $DIE;
sub BEGIN {
    $WARN = $SIG{__WARN__};
    $DIE = $SIG{__DIE__};
    foreach my $pkg (qw(Log::Dispatch Log::Dispatch::Output Log::Dispatch::Config), __PACKAGE__) {
        $Carp::Internal{$pkg}++;
    }
}

sub create_instance {
    my($class, $config) = @_;
    my $instance = $class->SUPER::create_instance($config);

    my $dispatchers = $config->get_attrs('dispatchers');
    my $_backup_and_resume = sub {
        my ($list, $callback) = @_;
        # backup & redefine
        my $backup = {};
        my $is_added_newline = 0;
        foreach my $disp (@{$dispatchers}) {
            my $config_disp = $config->get_attrs($disp);
            my $output = $instance->output($disp);
            $backup->{$disp} = $output->{callbacks};
            if ($config_disp->{newline} && !$is_added_newline) {
                push @{$list}, \&Log::Dispatch::Output::_add_newline_callback;
                $is_added_newline = 1;
            }
            $output->{callbacks} = $list;
        }
        $callback->();
        # resume
        foreach my $disp (@{$dispatchers}) {
            my $output = $instance->output($disp);
            $output->{callbacks} = $backup->{$disp};
        }
    };

    # define error message formats
    my $watch = $config->get_attrs('watch');
    my $formats = $watch->{formats};
    my $start = $formats->{start};
    my $end = $formats->{end};
    my $end_with_die = $formats->{end_with_die};
    my $die = $formats->{die};
    my $warn = $formats->{warn};
    my $timeover = $formats->{timeover};
    my $die_level = $watch->{die_level} || 'critical';
    my $warn_level = $watch->{warn_level} || 'warning';
    my $time_zone = DateTime::TimeZone->new( name => $config->get_attrs('time_zone') || 'local' );
    $instance->{time_zone} = $time_zone;

    # watching the start and the end of functions
    my $start_time;
    for my $subname ( keys %{$watch->{functions}} ) {
        my $conf = $watch->{functions}->{$subname};
        my $description = $conf->{description};
        my $warn_duration = $conf->{warn_duration};
        my $notice_duration = $conf->{notice_duration};
        eval {
            Hook::LexWrap::wrap $subname,
            pre => sub {
                $start_time = DateTime::HiRes->now(time_zone => $time_zone);
                $_backup_and_resume->(
                    [ $instance->format_to_cb($start, 2, '', $description), ],
                    sub { $instance->info(''); } );
            },
            post => sub {
                my $formatter = DateTime::Format::Duration->new({
                    pattern => '%H:%M:%S.%N',
                });
                my $duration = DateTime::HiRes->now(time_zone => $time_zone)->subtract_datetime_absolute($start_time);
                my $duration_sec = $duration->seconds + $duration->nanoseconds / 10**10;
                my $duration_str = $formatter->format_duration($duration);
                if ($warn_duration && $duration_sec > $warn_duration) {
                    $_backup_and_resume->(
                        [ $instance->format_to_cb($timeover, 2, '', $description, $duration_str), ],
                        sub { $instance->warning(''); } );
                }
                elsif ($notice_duration && $duration_sec > $notice_duration) {
                    $_backup_and_resume->(
                        [ $instance->format_to_cb($timeover, 2, '', $description, $duration_str), ],
                        sub { $instance->notice(''); } );
                }
                $_backup_and_resume->(
                    [ $instance->format_to_cb($end, 2, '', $description, $duration_str), ],
                    sub { $instance->info(''); } );
            };
        };
        warn $@ if $@;
    }

    # watching die
    if ($watch->{watch_die}) {
        $SIG{__DIE__} = sub {
            return if $watch->{watch_only_unexpected_die} && $^S;
            my $error_message = shift;
            chomp $error_message;
            my $subroutine = (caller 1)[3];
            if (exists $watch->{functions}->{$subroutine}) {
                my $description = $watch->{functions}->{$subroutine}->{'description'};
                $_backup_and_resume->(
                    [ $instance->format_to_cb($end_with_die, 2, $error_message, $description), ],
                    sub { $instance->log(level => $die_level, message => ''); } );
            }
            else {
                $_backup_and_resume->(
                    [ $instance->format_to_cb($die, 2, $error_message), ],
                    sub { $instance->log(level => $die_level, message => ''); } );
            }
            if ($DIE) {
                $DIE->($error_message);
            }
            else {
                CORE::die($error_message);
            }
        };
    }

    # watching warn
    if ($watch->{watch_warn}) {
        $SIG{__WARN__} = sub {
            my $warn_message = shift;
            chomp $warn_message;
            $_backup_and_resume->(
                [ $instance->format_to_cb($warn, 2, $warn_message), ],
                sub { $instance->log(level => $warn_level, message => ''); } );
            if ($WARN) {
                $WARN->($warn_message);
            }
            else {
                CORE::warn($warn_message);
            }
        };
    }

    return $instance;
}

sub format_to_cb {
    my($class, $format, $stack, $error, $description, $duration_str) = @_; # error を追加
    return unless defined $format;

    # caller() called only when necessary
    my $needs_caller = $format =~ /%[FLP]/;
    return sub {
    my %p = @_;
    $p{p} = delete $p{level};
    $p{m} = delete $p{message};
    $p{n} = "\n";
    $p{'%'} = '%';
    $p{e} = $error if defined $error; # warn|die
    $p{j} = $description if defined $description; # description of the function which observed
    $p{t} = $duration_str if defined $duration_str; # execution time of the function

    if ($needs_caller) {
        my $depth = 0;
        $depth++ while caller($depth) =~ /^Log::Dispatch/;
        $depth += $Log::Dispatch::Config::CallerDepth;
        @p{qw(P F L)} = caller($depth);
    }

    my $time_zone;
    if ($class->__instance) {
        no strict 'refs';
        $time_zone = $class->__instance->{time_zone}->{name};
    }
    elsif (ref $class eq __PACKAGE__) {
        no strict 'refs';
        $time_zone = $class->{time_zone}->{name};
    }

    my $log = $format;
    $log =~ s{
        (%[dD](?:{(.*?)})?)|   # $1: datetime $2: datetime fmt (add Large 'D')
        (?:%([%pmFLPnejt]))    # $3: others
    }{
        if ($1 && $2) {
            if ($1 =~ m{^d}xms) {
                _strftime($2);
            }
            # Starts with 'D'
            else {
                no strict 'refs';
                $time_zone = $time_zone ? $time_zone : 'Asia/Tokyo';
                DateTime::HiRes->now(
                    formatter => DateTime::Format::Strptime->new( pattern => $2 ),
                    time_zone => $time_zone,
                );
            }
        }
        elsif ($1) {
        scalar localtime;
        }
        elsif ($3) {
        $p{$3};
        }
    }egx;
    return $log;
    };
}

1;

__END__

=encoding utf-8

=head1 NAME

Log::Dispatch::Config::Watcher - Subclass of Log::Dispatch::Config that observes the start and the end of functions

=head1 SYNOPSIS

  #---------- code ----------
  use Log::Dispatch::Config::Watcher;
  use Log::Dispatch::Configurator::YAML;

  my $config = Log::Dispatch::Configurator::YAML->new('/path/to/log.yaml');
  Log::Dispatch::Config::Watcher->configure($config);
  my $log = Log::Dispatch::Config::Watcher->instance;

  $log->info('... log message ...');
  test1();
  test2();
  test3();

  sub test1 {
    $log->warn('sample warning.');
    sleep 4;
  }

  sub test2 {
    sleep 5;
    eval { die 'die with expected exception'; };
    warn $@ if $@;
  }

  sub test3 {
    die 'die with unexpected exception.';
  }

  #---------- yaml file ----------
  dispatchers:
    - screen
  screen:
    class: Log::Dispatch::Screen
    min_level: debug
    format: '[%p] %F:%L %m [%D{%F %T.%6N%z}]'
    newline: 1
    stderr: 1
  watch:
    watch_die: 1
    watch_only_unexpected_die: 1
    watch_warn: 1
    formats:
      start: '[%p] START:%j [%D{%F %T.%6N%z}]'
      end: '[%p] END:%j(%t) [%D{%F %T.%6N%z}]'
      end_with_die: '[%p] ABNORMALLY_ENDED:%j(%e) [%D{%F %T.%6N%z}]'
      die: '[%p] UNEXPECTED_DIE (%e) [%D{%F %T.%6N%z}]'
      warn: '[%p] PERL_WARNING (%e) [%D{%F %T.%6N%z}]'
      timeover: '[%p] TIMEOVER:%j(%t)'
    functions:
      main::test1:
        description: sleep 4 seconds process
        warn_duration: 5.0
        notice_duration: 3.5
      main::test3:
        description: sleep 5 seconds process
        warn_duration: 4.0
        notice_duration: 2.5

  #---------- results ----------
  [info] ./log.pl:13 ... log message ... [2010-07-30 15:34:16.316215+0900]

  [info] START:"sleep 4 seconds process" [2010-07-30 15:34:16.319123+0900]
  [warn] ./log.pl:19 sample warning. [2010-07-30 15:34:16.320854+0900]
  [notice] TIMEOVER:"sleep 4 seconds process"(=>00:00:04.005179167)
  [info] END:"sleep 4 seconds process"(=>00:00:04.005179167) [2010-07-30 15:34:20.324692+0900]

  [warning] PERL_WARNING (die with expected exception at ./log.pl line 25.)

  [info] START:"sleep 5 seconds process" [2010-07-30 15:34:25.328754+0900]
  [critical] ABNORMALLY_ENDED:"sleep 5 seconds process"(die with unexpected exception. at ./log.pl line 30.) [2010-07-30 15:34:25.330754+0900]


=head1 DESCRIPTION

This is a subclass of L<Log::Dispatch::Config> that can observe the start and the end of functions.

=head1 DESCRIPTION(japanese)

L<Log::Dispatch::Config::Watcher>はL<Log::Dispatch::Config>を継承し、関数の実行などを自動でログ出力できるように拡張したクラスです。

=head2 監視対象

=over

=item 1. 関数の起動と終了

指定された関数名の起動と終了を監視し、定められたフォーマットでログを出力します。また、経過時間を元にログレベルを切り替えることができます。

=item 2. warn と die

perl の warn と die を指定されたレベルのログに変換して出力します。SEE ALSO L<Log::WarnDie>

=back

=head2 フォーマット記述子の拡張

=over

=item %j

監視対象の関数の説明文(watch.formats.functions.[メソッド名].description)

=item %e

warn|die のエラー内容($@)

=item %t

監視対象の関数の実行時間

=item %D{...}

時刻の出力フォーマット
DateTime::Format::Strptime に渡すことのできるフォーマットを...に記述します。ナノセカンド単位で表示することが可能です。

=back

=head2 フォーマットの動的切替

同一のディスパッチクラス(Log::Dispatch::Outputのサブクラス)内で、次のフォーマットを個別に指定することができます。

=over

=item watch.formats.start

監視対象の関数の起動時に出力されるログのフォーマット

=item watch.formats.end

監視対象の関数の終了時に出力されるログのフォーマット

=item watch.formats.end_with_die

監視対象の関数の異常終了時に出力されるログのフォーマット

=item watch.formats.timeover

監視対象の関数の実行時間が指定時間(warn_duration|notice_duration)を超えた場合に出力されるログのフォーマット

=item watch.formats.die

die 時に出力されるログのフォーマット

=item watch.formats.warn

warn 時に出力されるログのフォーマット

=back

=head1 CONFIGURATION

Here is an example of the config file:

  dispatchers:
    - screen
  screen:
    class: Log::Dispatch::Screen
    min_level: debug
    format: '[%p] %F:%L %m [%D{%F %T.%6N%z}]'
    newline: 1
    stderr: 1
  watch:
    watch_die: 1
    watch_only_unexpected_die: 1
    watch_warn: 1
    formats:
      start: '[%p] START:%j [%D{%F %T.%6N%z}]'
      end: '[%p] END:%j(%t) [%D{%F %T.%6N%z}]'
      end_with_die: '[%p] ABNORMALLY_ENDED:%j(%e) [%D{%F %T.%6N%z}]'
      die: '[%p] UNEXPECTED_DIE (%e) [%D{%F %T.%6N%z}]'
      warn: '[%p] PERL_WARNING (%e)'
      timeover: '[%p] TIMEOVER:%j(%t)'
    functions:
      main::test1:
        description: sleep some seconds process
        warn_duration: 5.0
        notice_duration: 3.5
      main::test2:
        description: sleep some seconds process
        warn_duration: 4.0
        notice_duration: 2.5
  time_zone: Asia/Tokyo

=head1 DEPENDENCIES

=over

=item L<Log::Dispatch::Config>

=item L<Hook::LexWrap>

=item L<DateTime>

=item L<DateTime::HiRes>

=item L<DateTime::Format::Strptime>

=item L<DateTime::Duration>

=item L<DateTime::Format::Duration>

=back

=head1 AUTHOR

keroyon E<lt>keroyon@cpan.orgE<gt>

=head1 SEE ALSO

=over

=item L<Log::Dispatch::Config>

=item L<Log::Dispatch>

=item L<Log::WarnDie>

=back

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut




