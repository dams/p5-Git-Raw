package inc::MakeMaker;

use Moose;
use Config;

extends 'Dist::Zilla::Plugin::MakeMaker::Awesome';

override _build_MakeFile_PL_template => sub {
	my ($self) = @_;

	my $template = <<'TEMPLATE';
use strict;
use warnings;
use Config;
use Getopt::Long;
use File::Basename qw(basename dirname);
use File::Spec::Functions qw(rel2abs);

use Devel::CheckLib;

# compiler detection
my $is_gcc = length($Config{gccversion});
my $is_msvc = $Config{cc} eq 'cl' ? 1 : 0;
my $is_sunpro = (length($Config{ccversion}) && !$is_msvc) ? 1 : 0;

# os detection
my $is_solaris = ($^O =~ /(sun|solaris)/i) ? 1 : 0;
my $is_windows = ($^O =~ /MSWin32/i) ? 1 : 0;
my $is_linux = ($^O =~ /linux/i) ? 1 : 0;
my $is_osx = ($^O =~ /darwin/i) ? 1 : 0;
my $is_gkfreebsd = ($^O =~ /gnukfreebsd/i) ? 1 : 0;
my $is_netbsd = ($^O =~ /netbsd/i) ? 1 : 0;

# allow the user to override/specify the locations of OpenSSL, libssh2 and libcurl
our $opt = {};

Getopt::Long::GetOptions(
	"help" => \&usage,
	'with-openssl-include=s' => \$opt->{'ssl'}->{'incdir'},
	'with-openssl-libs=s@'   => \$opt->{'ssl'}->{'libs'},
	'with-libssh2-include=s' => \$opt->{'ssh2'}->{'incdir'},
	'with-libssh2-lib=s@'    => \$opt->{'ssh2'}->{'libs'},
	'with-libcurl-include=s' => \$opt->{'curl'}->{'incdir'},
	'with-libcurl-lib=s@'    => \$opt->{'curl'}->{'libs'},
) || die &usage();

my $def = '';
my $lib = '';
my $otherldflags = '';
my $inc = '';
my $ccflags = '';

my %os_specific = (
	'darwin' => {
		'ssh2' => {
			'inc' => ['/opt/local/include'],
			'lib' => ['/opt/local/lib']
		}
	},
	'freebsd' => {
		'ssh2' => {
			'inc' => ['/usr/local/include'],
			'lib' => ['/usr/local/lib']
		}
	},
	'netbsd' => {
		'ssh2' => {
			'inc' => ['/usr/pkg/include'],
			'lib' => ['/usr/pkg/lib']
		},
		'curl' => {
			'inc' => ['/usr/pkg/include'],
			'lib' => ['/usr/pkg/lib']
		}
	}
);

my ($ssh2_libpath, $ssh2_incpath);
my ($curl_libpath, $curl_incpath);
if (my $os_params = $os_specific{$^O}) {
	if (my $ssh2 = $os_params -> {'ssh2'}) {
		$ssh2_libpath = $ssh2 -> {'lib'};
		$ssh2_incpath = $ssh2 -> {'inc'};
	}
	if (my $curl = $os_params -> {'curl'}) {
		$curl_libpath = $curl -> {'lib'};
		$curl_incpath = $curl -> {'inc'};
	}
}

my @library_tests = (
	{
		'lib'     => 'ssh2',
		'libpath' => $ssh2_libpath,
		'incpath' => $ssh2_incpath,
		'header'  => 'libssh2.h',
	},
	{
		'lib'     => 'ssl',
		'header'  => 'openssl/opensslconf.h',
	},
	{
		'lib'     => 'curl',
		'libpath' => $curl_libpath,
		'incpath' => $curl_incpath,
		'header'  => 'curl/curl.h',
	},
);

my %library_opts = (
	'ssl' => {
		'defines' => ' -DGIT_OPENSSL -DGIT_SHA1_OPENSSL -DGIT_HTTPS',
		'libs'    => ' -lssl -lcrypto',
	},
	'ssh2' => {
		'defines' => ' -DGIT_SSH',
		'libs'    => ' -lssh2',
	},
	'curl' => {
		'defines' => ' -DGIT_CURL',
		'libs'    => ' -lcurl',
	}
);

# check for optional libraries
foreach my $test (@library_tests) {
	my $library = $test->{lib};
	my $user_library_opt = $opt->{$library};
	my $user_incpath = $user_library_opt->{'incdir'};
	my $user_libs = $user_library_opt->{'libs'};

	if ($user_incpath && $user_libs) {
		$inc .= " -I$user_incpath";

		# perform some magic
		foreach my $user_lib (@$user_libs) {
			my ($link_dir, $link_lib) = (dirname($user_lib), basename($user_lib));

			if (!$is_msvc) {
				my @tokens = grep { $_ } split(/(lib|\.)/, $link_lib);
				shift @tokens if ($tokens[0] eq 'lib');
				$link_lib = shift @tokens;
			}
			$lib .= " -L$link_dir -l$link_lib";
		}

		my $opts = $library_opts{$library};
		$opts->{'use'} = 1;

		$def .= $opts->{'defines'};

		print uc($library), " support enabled (user provided)", "\n";
	} elsif (check_lib(%$test)) {
		if (exists($test->{'incpath'})) {
			if (my $incpath = $test->{'incpath'}) {
				$inc .= ' -I'.join (' -I', @$incpath);
			}
		}

		if (exists($test->{'libpath'})) {
			if (my $libpath = $test->{'libpath'}) {
				$lib .= ' -L'.join (' -L', @$libpath);
			}
		}

		my $opts = $library_opts{$library};
		$opts->{'use'} = 1;

		$def .= $opts->{'defines'};
		$lib .= $opts->{'libs'};

		print uc($library), " support enabled", "\n";
	} else {
		print uc($library), " support disabled", "\n";
	}
}

# universally supported
$def .= ' -DNO_VIZ -DSTDC -DNO_GZIP -D_FILE_OFFSET_BITS=64 -D_GNU_SOURCE';

$def .= ' -DLIBGIT2_NO_FEATURES_H';

# supported on Solaris
if ($is_solaris) {
	$def .= ' -D_POSIX_C_SOURCE=200112L -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS';
}

# Time structures
if ($is_netbsd) {
	# Needed for stat.st_mtim / stat.st_mtimespec
	$def .= ' -D_NETBSD_SOURCE';

	if ((split (m|\.|, $Config{osvers}))[0] < 7) {
		$def .= ' -DGIT_USE_STAT_MTIMESPEC';
	} else {
		$def .= ' -DGIT_USE_STAT_MTIM';
	}
} elsif ($is_osx) {
	$def .= ' -DGIT_USE_STAT_MTIMESPEC';
} else {
	$def .= ' -DGIT_USE_STAT_MTIM';
}

# Nanosecond resolution
$def .= ' -DGIT_USE_STAT_MTIM_NSEC -DGIT_USE_NEC';

if ($is_gcc) {
	# gcc-like compiler
	$ccflags .= ' -Wall -Wno-unused-variable -Wno-pedantic -Wno-deprecated-declarations';

	# clang compiler is pedantic!
	if ($is_osx) {
		# clang masquerading as gcc
		if ($Config{gccversion} =~ /LLVM/) {
			$ccflags .= ' -Wno-unused-const-variable -Wno-unused-function';
		}

		# Secure transport (HTTPS)
		$def .= ' -DGIT_SECURE_TRANSPORT -DGIT_HTTPS -DGIT_SHA1_COMMON_CRYPTO';
		$otherldflags .= ' -framework CoreFoundation -framework Security';
	}

	if ($is_solaris) {
		$ccflags .= ' -std=c99';
	}

	# building with a 32-bit perl on a 64-bit OS may require this (supported by cc and gcc-like compilers,
	# excluding some ARM toolchains)
	if ($Config{ptrsize} == 4 && $Config{archname} !~ /arm/) {
		$ccflags .= ' -m32';
	}
} elsif ($is_sunpro) {
	# probably the SunPro compiler, (try to) enable C99 support
	$ccflags .= ' -xc99=all,no_lib';
	$def .= ' -D_STDC_C99';

	$ccflags .= ' -errtags=yes -erroff=E_EMPTY_TRANSLATION_UNIT -erroff=E_ZERO_OR_NEGATIVE_SUBSCRIPT';
	$ccflags .= ' -erroff=E_EMPTY_DECLARATION -erroff=E_STATEMENT_NOT_REACHED';
}

# there are no atomic primitives for the Sun Pro compiler in libgit2, so even if pthreads is available
# and perl has been built with threads support, libgit2 cannot use threads under said compiler
if ($Config{usethreads} && !$is_sunpro) {
	if (check_lib(lib => 'pthread')) {
		$def .= ' -DGIT_THREADS';
		$lib .= ' -lpthread';

		print "Threads support enabled\n";
	} else {
		if ($is_windows) {
			$def .= ' -DGIT_THREADS';
		} else {
			print "Threads support disabled (pthreads not found)\n";
		}
	}
} elsif ($is_sunpro) {
	print "Thread support disabled (SunPro compiler detected)\n"
} else {
	print "Thread support disabled (perl wasn't built with thread support)\n"
}

my @deps = glob 'deps/libgit2/deps/{http-parser,zlib}/*.c';
my @srcs = glob 'deps/libgit2/src/{*.c,transports/*.c,xdiff/*.c,streams/*.c}';
my @incs = ('.', 'deps/libgit2', 'deps/libgit2/src', 'deps/libgit2/include', 'deps/libgit2/deps/http-parser', 'deps/libgit2/deps/zlib');

if ($is_msvc) {
	push @srcs, 'deps/libgit2/src/hash/hash_win32.c';
}
elsif (!$library_opts{'ssl'}{'use'} && !$is_osx) {
	push @srcs, 'deps/libgit2/src/hash/hash_generic.c';
}

# the system regex is broken on Solaris, not available on Windows
if ($is_windows || $is_solaris) {
	push @srcs, 'deps/libgit2/deps/regex/regex.c';
	push @incs, 'deps/libgit2/deps/regex';
}

if ($is_windows) {
	push @srcs, glob 'deps/libgit2/src/{win32,compat}/*.c';

	$def .= ' -DWIN32 -DGIT_WIN32 -DGIT_WINHTTP -DGIT_HTTPS';
	$lib .= ' -lwinhttp -lrpcrt4 -lcrypt32';

	if ($is_msvc) {
		# visual studio compiler
		$def .= ' -D_CRT_SECURE_NO_WARNINGS -DGIT_SHA1_WIN32';
	} else {
		# mingw/cygwin
		$def .= ' -D_WIN32_WINNT=0x0501 -D__USE_MINGW_ANSI_STDIO=1';
	}
} else {
	push @srcs, glob 'deps/libgit2/src/unix/*.c'
}

# real-time library is required for Solaris and Linux
if ($is_linux || $is_solaris || $is_gkfreebsd) {
	$lib .= ' -lrt';
}

# absolute to relative conversion (UNIX)
my $transform = $is_windows ? sub { shift } : \&rel2abs;
@srcs = map { $transform->($_) } @srcs;
@deps = map { $transform->($_) } @deps;
foreach my $i (@incs)
{
	$inc .= ' -I'.$transform->($i);
}

my @objs = map { substr ($_, 0, -1) . 'o' } (@deps, @srcs);

sub MY::c_o {
	my $out_switch = '-o ';

	if ($is_msvc) {
		$out_switch = '/Fo';
	}

	my $line = qq{
.c\$(OBJ_EXT):
	\$(CCCMD) \$(CCCDLFLAGS) "-I\$(PERL_INC)" \$(PASTHRU_DEFINE) \$(DEFINE) \$*.c $out_switch\$@

Raw$(OBJ_EXT) :: @objs
};

	return $line;
}

if ($is_windows && !$is_msvc) {
	my $def_file = "deps/libgit2/deps/winhttp/winhttp.def";
	if ($Config{ptrsize} == 8) {
		$def_file = "deps/libgit2/deps/winhttp/winhttp64.def";
	}

	my $result = system ('dlltool', '-d', $def_file, '-k', '-D', 'winhttp.dll', '-l', 'libwinhttp.a');
	if ($result << 8 != 0) {
		print STDERR "Failed to generate libwinhttp.a: $!\n";
		exit(1);
	}
}

# This Makefile.PL for {{ $distname }} was generated by Dist::Zilla.
# Don't edit it but the dist.ini used to construct it.
{{ $perl_prereq ? qq[BEGIN { require $perl_prereq; }] : ''; }}
use strict;
use warnings;
use ExtUtils::MakeMaker {{ $eumm_version }};
use ExtUtils::Constant qw (WriteConstants);

{{ $share_dir_block[0] }}
my {{ $WriteMakefileArgs }}

$WriteMakefileArgs{MIN_PERL_VERSION}  = '5.8.8';
$WriteMakefileArgs{DEFINE}  .= $def;
$WriteMakefileArgs{LIBS}    .= $lib;
$WriteMakefileArgs{INC}     .= $inc;
$WriteMakefileArgs{CCFLAGS} .= $Config{ccflags} . ' '. $ccflags;
$WriteMakefileArgs{OBJECT}  .= ' ' . join ' ', @objs;
$WriteMakefileArgs{dynamic_lib} = {
	OTHERLDFLAGS => $otherldflags
};
$WriteMakefileArgs{clean} = {
	FILES => "*.inc"
};

unless (eval { ExtUtils::MakeMaker->VERSION(6.56) }) {
	my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
	my $pp = $WriteMakefileArgs{PREREQ_PM};

	for my $mod (keys %$br) {
		if (exists $pp -> {$mod}) {
			$pp -> {$mod} = $br -> {$mod}
				if $br -> {$mod} > $pp -> {$mod};
		} else {
			$pp -> {$mod} = $br -> {$mod};
		}
	}
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
	unless eval { ExtUtils::MakeMaker -> VERSION(6.52) };

my @error_constants = (qw(
	OK
	ERROR
	ENOTFOUND
	EEXISTS
	EAMBIGUOUS
	EBUFS
	EBAREREPO
	EUNBORNBRANCH
	EUNMERGED
	ENONFASTFORWARD
	EINVALIDSPEC
	ECONFLICT
	ELOCKED
	EMODIFIED
	EAUTH
	ECERTIFICATE
	EAPPLIED
	EPEEL
	EEOF
	EINVALID
	EUNCOMMITTED
	EDIRECTORY
	EMERGECONFLICT
	PASSTHROUGH

	ASSERT
	USAGE
	RESOLVE
));

my @category_constants = (qw(
	NONE
	NOMEMORY
	OS
	INVALID
	REFERENCE
	ZLIB
	REPOSITORY
	CONFIG
	REGEX
	ODB
	INDEX
	OBJECT
	NET
	TAG
	TREE
	INDEXER
	SSL
	SUBMODULE
	THREAD
	STASH
	CHECKOUT
	FETCHHEAD
	MERGE
	SSH
	FILTER
	REVERT
	CALLBACK
	CHERRYPICK
	DESCRIBE
	REBASE
	FILESYSTEM

	INTERNAL
));

my @packbuilder_constants = (qw(
	ADDING_OBJECTS
	DELTAFICATION
));

my @stash_progress_constants = (qw(
	NONE
	LOADING_STASH
	ANALYZE_INDEX
	ANALYZE_MODIFIED
	ANALYZE_UNTRACKED
	CHECKOUT_UNTRACKED
	CHECKOUT_MODIFIED
	DONE
));

my @rebase_operation_constants = (qw(
	PICK
	REWORD
	EDIT
	SQUASH
	FIXUP
	EXEC
));

my @object_constants = (qw(
	ANY
	BAD
	COMMIT
	TREE
	BLOB
	TAG
));


ExtUtils::Constant::WriteConstants(
	NAME         => 'Git::Raw::Error',
	NAMES        => [@error_constants],
	DEFAULT_TYPE => 'IV',
	C_FILE       => 'const-c-error.inc',
	XS_FILE      => 'const-xs-error.inc',
	XS_SUBNAME   => '_constant',
	C_SUBNAME    => '_error_constant',
);

ExtUtils::Constant::WriteConstants(
	NAME         => 'Git::Raw::Error::Category',
	NAMES        => [@category_constants],
	DEFAULT_TYPE => 'IV',
	C_FILE       => 'const-c-category.inc',
	XS_FILE      => 'const-xs-category.inc',
	XS_SUBNAME   => '_constant',
	C_SUBNAME    => '_category_constant',
);

ExtUtils::Constant::WriteConstants(
	NAME         => 'Git::Raw::Packbuilder',
	NAMES        => [@packbuilder_constants],
	DEFAULT_TYPE => 'IV',
	C_FILE       => 'const-c-packbuilder.inc',
	XS_FILE      => 'const-xs-packbuilder.inc',
	XS_SUBNAME   => '_constant',
	C_SUBNAME    => '_packbuilder_constant',
);

ExtUtils::Constant::WriteConstants(
	NAME         => 'Git::Raw::Stash::Progress',
	NAMES        => [@stash_progress_constants],
	DEFAULT_TYPE => 'IV',
	C_FILE       => 'const-c-stash-progress.inc',
	XS_FILE      => 'const-xs-stash-progress.inc',
	XS_SUBNAME   => '_constant',
	C_SUBNAME    => '_stash_progress_constant',
);

ExtUtils::Constant::WriteConstants(
	NAME         => 'Git::Raw::Rebase::Operation',
	NAMES        => [@rebase_operation_constants],
	DEFAULT_TYPE => 'IV',
	C_FILE       => 'const-c-rebase-operation.inc',
	XS_FILE      => 'const-xs-rebase-operation.inc',
	XS_SUBNAME   => '_constant',
	C_SUBNAME    => '_rebase_operation_constant',
);

ExtUtils::Constant::WriteConstants(
	NAME         => 'Git::Raw::Object',
	NAMES        => [@object_constants],
	DEFAULT_TYPE => 'IV',
	C_FILE       => 'const-c-object.inc',
	XS_FILE      => 'const-xs-object.inc',
	XS_SUBNAME   => '_constant',
	C_SUBNAME    => '_object_constant',
);

WriteMakefile(%WriteMakefileArgs);
exit(0);

sub usage {
	print STDERR << "USAGE";
Usage: perl $0 [options]

Possible options are:
  --with-openssl-include=<path>    Specify <path> for the root of the OpenSSL installation.
  --with-openssl-libs=<libs>       Specify <libs> for the OpenSSL libraries.
  --with-libssh2-include=<path>    Specify <path> for the root of the libssh2 installation.
  --with-libssh2-lib=<lib>         Specify <lib> for the libssh2 library.
USAGE

	exit(1);
}

{{ $share_dir_block[1] }}
TEMPLATE

	return $template;
};

override _build_WriteMakefile_args => sub {
	return +{
		%{ super() },
		#INC	    => '-I. -Ideps/libgit2 -Ideps/libgit2/src -Ideps/libgit2/include -Ideps/libgit2/deps/http-parser -Ideps/libgit2/deps/zlib',
		OBJECT	=> '$(O_FILES)',
	}
};

__PACKAGE__ -> meta -> make_immutable;
