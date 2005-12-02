# $Id: Build.PL,v 1.6 2005/12/02 15:25:36 asc Exp $

use strict;
use Module::Build;

my $build = Module::Build->new(module_name => 'MT::Import::Mbox::Importer',
			       # dist_author
			       # dist_abstract
			       dist_version_from => 'lib/MT/Import/Mbox/Importer.pm',
			       license           => 'perl',
			       requires => {
				   'Date::Parse'            => '',
				   'MT::Import::Mbox'       => '>= 1.0',
				   'Config::Simple'         => '',
				   'File::Find::Rule'       => '',
				   'Log::Dispatch'          => '',
				   'Memoize'                => '',
			       },
			       build_requires => {
				   'Test::Simple' => '>= 0.47',
			       },
			       create_readme      => 1,
			       create_makefile_pl => 'passthrough');

$build->create_build_script();
