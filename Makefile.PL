use inc::Module::Install;
name 'Log-Dispatch-Config-Watcher';
all_from 'lib/Log/Dispatch/Config/Watcher.pm';
readme_from 'lib/Log/Dispatch/Config/Watcher.pm';
readme_markdown_from 'lib/Log/Dispatch/Config/Watcher.pm';
readme_pod_from 'lib/Log/Dispatch/Config/Watcher.pm';
githubmeta;

requires 'Log::Dispatch::Config';
requires 'Log::Dispatch::Configurator::YAML';
requires 'Hook::LexWrap';
requires 'DateTime';
requires 'DateTime::HiRes';
requires 'DateTime::Format::Strptime';
requires 'DateTime::Duration';
requires 'DateTime::Format::Duration';

tests 't/*.t';
author_tests 'xt';

build_requires 'Test::More';
auto_set_repository;
auto_include;
WriteAll;
