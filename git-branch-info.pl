#!/usr/bin/perl
use warnings;
use version;
use strict;
use threads;
use threads::shared;
use Getopt::Long;
use Pod::Usage;
use File::Basename;
use Data::Dumper;
use Thread::Queue;

our $VERSION=0.1;

my $RED="\e[31m";
my $BLUE="\e[36m";
my $WHITE="\e[37m";
my $GREEN="\e[32m";
my $NO="\e[0m";
my $sep='~~~';

my $nocommit;
my $nofetch;
my $anyterm;
my $notag;
my $chosenrelease=".";
my $daysago;
my $threadcount=8;

GetOptions(
	"c|no-commit" => \$nocommit,
	"f|no-fetch" => \$nofetch,
	"a|anyterm" => \$anyterm,
	"t|no-tag" => \$notag,
	"r|release=s" => \$chosenrelease,
	"d|days-ago=i" => \$daysago,
	"threads=i" => \$threadcount,
);

pod2usage("Search term must be provided and must reference a Version One item unless -a is specified")
unless (defined $ARGV[0] && ($ARGV[0] =~ /^[DSI]-[0-9]+$/ || defined $anyterm));

my @allreleases = (
	{
		title => "master",
		stream => "origin/tm-master2",
		target => "origin/master",
		prefix => "^7"
	},
	{
		title => "R14.3",
		stream => "origin/tm-master2-r14",
		target => "origin/R14-master",
		prefix => "^14.3."
	},
	{
		title => "R14.2",
		stream => "origin/tm-master2-r14.2.0",
		target => "origin/R14.2",
		prefix => "^14.2."
	},
	{
		title => "R14.1",
		stream => "origin/tm-master2-r14.1",
		target => "origin/R14.1",
		prefix => "^14.1."
	},
	{
		title => "R13.11",
		stream => "origin/tm-master2-r13.11",
		target => "origin/R13.11",
		prefix => "^13.11."
	},

);

my @releases = grep { $_->{'title'} =~ /$chosenrelease/ } @allreleases;

my $branchlist = "";
my @untracked=();
my %patchIds :shared;
my @progressbar :shared =();
my $outputqueue = Thread::Queue->new();

sub getPatchId{
	my $commit=shift;
	my @ids = split / /, `git show $commit | git patch-id`;
	if (@ids){
		my $patchId =  $ids[0];
		if (defined $patchIds{$patchId}){
			$patchIds{$patchId};
		} else {
			my $newId = keys %patchIds;
			$patchIds{$patchId} = $newId;
		}
	} else {
		my $newId = keys %patchIds;
		$patchIds{$newId."M"} = $newId."M";
	}

}

sub getCommits{
	my $searchterm=shift;
	my $since = $daysago ? qq/--since="$daysago days ago" / : "";
	my $changecmd=qq/git log $since --all --pretty=format:%H$sep%s:%an$sep%cr --grep $searchterm/;
	my @changes=`$changecmd`;
}


sub filterTags {
	my $versionsRef = shift;
	my $rev = shift;
	my @sortedVersions = sort { version->parse($a) <=> version->parse($b) } @$versionsRef;
	@sortedVersions = reverse @sortedVersions if defined $rev;
	my @filteredTags = ();
	for my $release (@releases) {
		my $firstBranchTag = (grep { /$release->{prefix}/ } @sortedVersions)[0];
		if (defined $firstBranchTag) {
			push @filteredTags, $firstBranchTag unless grep { /$firstBranchTag/ } @filteredTags ;
		}
	}
	\@filteredTags;
}

sub getTags{
	if (defined $notag){
		return [];
	}
	my $commit = shift;
	my @tags = grep { $_ =~ /build-linux-([0-9]+\.?)+/ } `git tag --contains $commit`;

	if ($tags[0]) {
		s{^\s+|\s+$}{}g foreach @tags;
		chomp(my @versions = map { (split (/-/))[-1];} @tags);
		return filterTags (\@versions);
	} else {
		return [];
	}

}

sub printbar{
	my $index = shift;
	my $character = shift;
	lock (@progressbar);
	$progressbar[$index] = $character;
	print "\rProcessing commits [". join ("", @progressbar)."]";
}

sub processChange {
	my $change = shift;
	my $index = shift;
	my %hash=();
	printbar($index,".");
	chomp((my $commit, my $comment, my $date) = split /$sep/, $change);
	my @branches = `git branch -a --contains $commit --list $branchlist`;
	printbar($index,":");
	if (@branches){
		my %branchset = map { s:^\s+remotes/|\s+$::g;$_ => 1 } @branches;
		my $patchId = "[" . getPatchId($commit) . "]";
		printbar($index,"|");
		my $commitdescription = $commit . "(applied $date) ";
		my @tags = @{getTags($commit)};
		my $finalcolor = "";
		for my $release (@releases){
			my $releasetitle = $release->{"title"};
			my $releasestatus = "";
			my $releasecolour = "";
			if ($branchset{$release->{"stream"}}) {
				$releasestatus .= "${RED}TM ${NO}";
				$releasecolour = $RED;
				$finalcolor ||= $RED;
			}
			if ($branchset{$release->{"target"}}) {
				my $buildTag = (grep { /$release->{'prefix'}/ } @tags)[0];
				if (defined $buildTag){
					$releasestatus .= "$GREEN TITAN [$buildTag]";
					$finalcolor = $releasecolour = $GREEN;
				} else {
					$releasestatus .= "$BLUE TITAN";
					$finalcolor = $releasecolour = $BLUE if $finalcolor ne $GREEN;
				}
				$releasestatus .= "$NO";
			}
			if ($releasestatus){
				$commitdescription .= "$releasecolour$releasetitle$NO [$releasestatus] "
			}
		}
		push (@{$hash{$comment}{'commits'}{$patchId}}, $commitdescription);
		push (@{$hash{$comment}{'tags'}{$patchId}}, @tags);
		printbar($index,"$finalcolor#$NO");
	} else {
		push @untracked, $change;
		printbar($index,"x");
	}
	#return %hash;
	$outputqueue->enqueue(\%hash);
}

sub tagString{
	my $tags = shift;
	my $tagstring = "";
	for my $release (@releases){
		my $releasetitle = $release->{"title"};
		my $buildTag = (grep { /$release->{'prefix'}/ } @{$tags})[0];
		if (defined $buildTag){
			$tagstring .= " $GREEN${releasetitle}[$buildTag]$NO";
		}
	}
	$tagstring;
}

if (defined $nofetch) {
	print "Skipping fetch\n";
} else {
	print "Fetching [ ]\b\b";
	`git fetch 2>&1` ;
	print $? ? "Failed]\n" : "#\n";

}

my @changes = getCommits($ARGV[0]);
my $totalCommits = @changes;
push @progressbar, " " for (1..$totalCommits);
printbar(0," ");

for my $release (@releases){
	my @branches = @{$release}{'stream', 'target'};
	$branchlist = join " ", $branchlist, @branches;
}

my @threads = ();
my $index = 0;
my $inputqueue = Thread::Queue->new();
for my $change (@changes) {
	$inputqueue->enqueue([$change,$index++]);
}

for (1..$threadcount){
		my ($t) = threads->create(sub {while (defined(my $work = $inputqueue->dequeue_nb())){(my $change, my $index) = @{$work}; processChange ($change,$index)}});
		push(@threads, $t);
}
foreach (@threads) {
	$_->join();
}


my %hash = ();
while (my $changehashref = $outputqueue->dequeue_nb()) {
	my %changehash = %{$changehashref};
	for my $comment (keys %{changehash}) {
		for my $patchId (keys %{$changehash{$comment}{'commits'}}) {
			push (@{$hash{$comment}{'commits'}{$patchId}}, @{$changehash{$comment}{'commits'}{$patchId}});
			push (@{$hash{$comment}{'tags'}{$patchId}}, @{$changehash{$comment}{'tags'}{$patchId}});
		}
	}
}
print "\n";


my @alltags = ();
for my $comment (sort keys %hash) {
	print "\n$WHITE$comment$NO\n";
	for my $patchId (sort keys %{$hash{$comment}{'commits'}}){
		my $filteredTags = filterTags ($hash{$comment}{'tags'}{$patchId});
		push @alltags, @{$filteredTags};
		my $patchtags = tagString($filteredTags);
		print "\tPatch $patchId $patchtags\n";
		unless (defined $nocommit){
			my $commitlist = $hash{$comment}{'commits'}{$patchId};
			for my $commit (@{$commitlist}){
				print "\t\t$commit\n";
			}
		}
	}
}
my $overallTags = tagString(filterTags(\@alltags, 1));
print "\nLatest referenced builds by release: ". $overallTags . "\n";
print "Changes not on any of ($branchlist)\n", @untracked if @untracked;

__END__

=head1 SYNOPSIS

findchange.pl [-caftrd] searchterm

	-c|no-commit  hide commit details
	-d|days-ago <days> only show commits after <days> ago
	-a|anyterm use any string for search (not just version one ID)
	-f|no-fetch do not 'git fetch' before processing
	-t|no-tag do not get version numbers (faster)
	-r|release <master|R14.1|R14.2|R14.3|R13.11> choose branch to query
	-threads specify how many threads to use

While the script is processing the commits a progress bar is shown. Characters can be interpreted as follows:

	.	Started processing commit
	:	Patch id calculation complete
	|	Branch query complete
	x	Commit is not on a release branch
	#	Commit is on at least one release branch. RED if the commit is only on the TM stream branch, BLUE if it's on a main Titan branch but not yet built and GREEN if there's an assigned build number
