package TGI::Mutpro::Main::Significance;
#
#----------------------------------
# $Authors: Adam D Scott, Carolyn Lou, and Sohini Sengupta
# $Date: 2015-09-22
# $Revision:$2017-03-12
# $URL: $
# $Doc: $ cluster significance
#----------------------------------
#
use strict;
use warnings;

use Carp;
use Getopt::Long;
use IO::File;
use FileHandle;

use Scalar::Util qw( reftype );

sub new {
	my $class = shift;
	my $this = {};
	$this->{'prep-dir'} = undef;
	$this->{'pairwise'} = undef;
	$this->{'clusters'} = undef;
	$this->{'output'} = "hotspot3d.sigclus";
	$this->{'simulations'} = 1000000;
	bless $this, $class;
	$this->process();
	return $this;
}

sub process {
	my $this = shift;
	my ( $help, $options );
	unless( @ARGV ) { die $this->help_text(); }
	$options = GetOptions (
		'prep-dir=s' => \$this->{'prep_dir'},
		'pairwise=s' => \$this->{'pairwise'},
		'clusters=s' => \$this->{'clusters'},
		'output=s' => \$this->{'output_prefix'},
		'simulations=i' => \$this->{'simulations'},
		'help' => \$help,
	);
	#my $NSIMS = $this ->{'simulations'};

	if ( $help ) { print STDERR help_text(); exit 0; }
	unless( $options ) { die $this->help_text(); }

	my $hup_file = $this->{'prep_dir'}."/hugo.uniprot.pdb.transcript.csv";
#	my $hup_file = $this->{'prep_dir'}."/test_hugo";
	my $proximity_dir = $this->{'prep_dir'}."/proximityFiles/cosmicanno/";

#if hup file missing
	if(not defined $hup_file ) {
		warn 'You must provide a hup file !', "\n"; 
		die $this->help_text();
		if(not -e $hup_file){
			warn "The input hup file(".$hup_file.") does not exist! ", "\n";
			die $this->help_text();
		}
	}

#if proximity directory missing
	unless( $proximity_dir ) {
		warn 'You must provide a proximity file directory ! ', "\n";
		die help_text();
	}
	unless( -d $proximity_dir ) {
		warn 'You must provide a valid proximity file directory ! ', "\n";
		die help_text();
	}

#processing procedure
#Read pairwise and store info
	my $cluster_f= $this->{'clusters'}; #debug
	my ($structures, $minMax)=$this->storePairwise($cluster_f);

#retrieve cluster information
	my ($clusters, $clus_store, $recurrence, $represent) = $this->getClusters($cluster_f, $structures);

#retrieve best structure
	my $bestStruc=$this->getBestStructure($clus_store,$represent, $minMax);

# parse hup file
	my ($genesOnPDB_hash_ref, $uniprot2HUGO_hash_ref, $HUGO2uniprot_hash_ref) = $this->processHUP( $hup_file ,$clusters);

#parse aaabbrv file
	my $AA_hash_ref = $this->processAA( );


#retrieve locations of mutations in clusters
	my ($withinClusterSumDistance,$mass2pvalues)= $this->getPairwise( $clusters , $genesOnPDB_hash_ref,$bestStruc, $recurrence);
#process everything
	$this ->getDistances($proximity_dir, $genesOnPDB_hash_ref, $HUGO2uniprot_hash_ref, $AA_hash_ref, $this->{'simulations'}, $clusters,$bestStruc, $clus_store, $recurrence, $withinClusterSumDistance,$mass2pvalues)
} 

#####
#	Subs
#####
# process HUP file
sub processHUP{
	print "processing HUP\n";
	my($this, $hup_f, $cluster) = @_;
	my $hupHandle = &getFile( $hup_f , "r" );
	unless ($hupHandle->open($hup_f)){die "Could not open hup file ".$hup_f."!\n"};
#	print "$cluster\n";#debug	
	my ( %genesOnPDB, %uniprot2HUGO, %HUGO2uniprot);
	while (my $line = $hupHandle->getline){
		chomp($line);
		my ( $hugo , $uniprot , $pdbs ) = ( split( "\t" , $line ) )[0,1,2];
	#	print "hup file pdbs: $pdbs\n"; #debug
		if( exists $cluster->{$hugo}){ #retrieve hup information only for specified clusters
			foreach my $pdb ( split(/\s/ , $pdbs)  ) {
				$genesOnPDB{$hugo}{$pdb} = 1;
				print "hugos: $hugo\n";#debug
			}
			$uniprot2HUGO{$uniprot}{$hugo} = 1;
			$HUGO2uniprot{$hugo} = $uniprot;
			print "HUGO: $hugo\n";
		}
	}
	$hupHandle->close();
	return (\%genesOnPDB, \%uniprot2HUGO, \%HUGO2uniprot);
}

#read in amino acid information
sub processAA {
	my( $this ) = @_;
	my %AA;
	my ( $single , $triple );
	my @lines = <DATA>;
	foreach my $line ( @lines ) { #organized with single letter, three-letter, and full name of amino acids
		chomp( $line );
		( $single , $triple ) = ( split( /\t/ , $line ) )[0,1];
		$AA{$triple} = $single;
	}
	return \%AA;
}

sub storePairwise{
	my ($this,$cluster_f)=@_;
	my $pairwiseHandle = &getFile( $this->{'pairwise'},"r" );

	my %structures;
	my %represent;
	my $minMax = {};
	while ( my $line = <$pairwiseHandle> ) {
		chomp( $line );
		my ( $gene1 , $mutation1 , $chain1 , $residue1 , $gene2 , $mutation2 , $chain2 , $residue2 , $pdbInfos ) = (split( "\t" , $line ))[0,4,5,6,9,13,14,15,19];
		$chain1 =~ s/\[(.*)\]/$1/;
		$chain2 =~ s/\[(.*)\]/$1/;
		my @pdbInfos = split( '\|' , $pdbInfos );
		foreach my $pdbInfo ( @pdbInfos ) {
			my $pdb = (split( ' ' , $pdbInfo ))[1];
			$structures{$gene1}{$mutation1}{$pdb}{$chain1} = $residue1;
			$structures{$gene2}{$mutation2}{$pdb}{$chain2} = $residue2;
			&checkMin( $minMax , $pdb , $gene1 , $chain1 , $residue1 );
			&checkMin( $minMax , $pdb , $gene2 , $chain2 , $residue2 );
			&checkMax( $minMax , $pdb , $gene1 , $chain1 , $residue1 );
			&checkMax( $minMax , $pdb , $gene2 , $chain2 , $residue2 );
		} #foreach pdbInfo in pdbInfos
	}
	$pairwiseHandle->close();
	
	return (\%structures,$minMax);
}

sub getClusters { #get cluster id for gene and mutation
	print "getting clusters now\n";
	my ($this, $cluster_f,$structures) = @_;

	my $cluster;
	my %clusters;
	my %clus_store;
	my %recurrence;
	my %represent;

	my $clustersHandle = &getFile( $cluster_f, "r" );
	while ( my $line = <$clustersHandle> ) {
		chomp( $line );
		if ($line!~/Cluster/){
			my ( $clusterid , $gene , $mutation, $weight ) = (split( /\t/ , $line ))[0..2,6];
			my @genes;
			if (exists $clus_store{$clusterid}){
				@genes=@{$clus_store{$clusterid}};
				if(! grep $_ eq $gene, @genes){
					push(@genes, $gene);
				}
			
			}
			else{
				@genes=($gene);
			}
			$clusters{$gene}{$mutation} = $clusterid;
			$recurrence{$clusterid}{$mutation}=int($weight);
			$clus_store{$clusterid}=\@genes;

			foreach my $pdb ( keys %{$structures->{$gene}->{$mutation}} ) {
				foreach my $chain ( keys %{$structures->{$gene}->{$mutation}->{$pdb}} ) {
					$represent{$pdb}{$gene}{$chain}{$clusterid}{$mutation.":".$structures->{$gene}->{$mutation}->{$pdb}->{$chain}} = $weight;
				}
			}
		}
	}
	$clustersHandle->close();
	return \%clusters, \%clus_store,\%recurrence,\%represent;
}



sub getBestStructure{
	my ( $this,$clus_store,$represent, $minMax) = @_;
	my %complex;
	my %bestStruc;
	foreach my $pdb ( sort keys %{$represent} ) {
		foreach my $gene ( sort keys %{$represent->{$pdb}} ) {
			foreach my $chain ( sort keys %{$represent->{$pdb}->{$gene}} ) {
				$chain =~ m/\[(.*)\]/;
				foreach my $cluster ( sort keys %{$represent->{$pdb}->{$gene}->{$chain}} ) {
					my ( $mutres , $mutation , $position );
					my @mutations;
					my %residues;
					my $recurrence = 0;
					foreach my $mutpos ( sort keys %{$represent->{$pdb}->{$gene}->{$chain}->{$cluster}} ) {
						( $mutation , $position ) = split( ":" , $mutpos );
						$recurrence += $represent->{$pdb}->{$gene}->{$chain}->{$cluster}->{$mutpos};
						$mutres = join( "|" , ( $mutation , $position ) );
						push @mutations , $mutres;
						$residues{$position} = 1;
					}
					if ( exists $minMax->{$pdb}->{$gene}->{$chain} ) {
						my $min = $minMax->{$pdb}->{$gene}->{$chain}->{'min'};
						my $max = $minMax->{$pdb}->{$gene}->{$chain}->{'max'};
						my @outline = ( $pdb , $gene , $chain , $cluster , $min , $max , scalar @mutations , scalar keys %residues , $recurrence , join( ";" , @mutations ) );
						$complex{$cluster}{$pdb}{$gene}{$chain} = \@outline;
					}
				}
			}
		} #foreach pdb in represent => cluster
	} #foreach cluster in represent

	foreach my $cluster ( sort keys %complex ) {
		foreach my $pdb ( sort keys %{$complex{$cluster}} ) {
			my ( @mutations , @geneChains );
			my ( $mutations , $residues , $recurrence );
			foreach my $gene ( sort keys %{$complex{$cluster}{$pdb}} ) {
				my @chains;
				foreach my $chain ( sort keys %{$complex{$cluster}{$pdb}{$gene}} ) {
					my @outline = @{$complex{$cluster}{$pdb}{$gene}{$chain}};
					$mutations += $outline[6];
					$residues += $outline[7];
					$recurrence += $outline[8];
					push @chains , $chain;
					push @mutations , $chains[-1]."\\";
					$mutations[-1] .= $outline[-1];
				} #foreach chain
				push @geneChains , $gene."|".join( "/" , @chains );
			} #foreach gene
			my @complexLine = ( $cluster , $pdb , join( ";" , @geneChains ) , $mutations , $residues , $recurrence , join( ";" , @mutations ) );

			my @pair=(int($recurrence),$pdb);
			print"$cluster\n";
			if (exists $clus_store->{$cluster} ){
				print"cluster id exists\n";
				if (exists $bestStruc{$cluster}){
						my $test=$bestStruc{$cluster}->[0];
						if(int($recurrence)> $test){
							$bestStruc{$cluster}=\@pair;
							print"new pair stored\n";
							print"$cluster\t$recurrence\t$pdb\n";
						}
				}
				else{
					$bestStruc{$cluster}=\@pair;
				}
			}


		} #foreach pdb
	} #foreach cluster

	return \%bestStruc;
}

sub checkMin {
	my ( $minMax , $pdb , $gene , $chain , $residue ) = @_;
	return unless ( $residue =~ /^\d+$/ );
	if ( exists $minMax->{$pdb}->{$gene}->{$chain}->{'min'} ) {
		if ( $minMax->{$pdb}->{$gene}->{$chain}->{'min'} <= $residue ) {
			return;
		}
	}
	$minMax->{$pdb}->{$gene}->{$chain}->{'min'} = $residue;
}

sub checkMax {
	my ( $minMax , $pdb , $gene , $chain , $residue ) = @_;
	return unless ( $residue =~ /^\d+$/ );
	if ( exists $minMax->{$pdb}->{$gene}->{$chain}->{'max'} ) {
		if ( $minMax->{$pdb}->{$gene}->{$chain}->{'max'} >= $residue ) {
			return;
		}
	}
	$minMax->{$pdb}->{$gene}->{$chain}->{'max'} = $residue;
}





sub getPairwise {
	print "getting pairwise now\n"; #debug
	my ( $this , $clusters , $genesOnPDBref,$bestStruc, $recurrence) = @_;
	my $pairwiseHandle = &getFile( $this->{'pairwise'},"r" );
	my (%mass2pvalues,%withinClusterSumDistance);
	while ( my $line = <$pairwiseHandle> ) {
		chomp( $line );
		my @line = split( /\t/ , $line );
		my ( $gene1 , $mu1 , $chain1 , $res1 , $gene2 , $mu2 , $chain2 , $res2 , $info ) = @line[0,4,5,6,9,13,14,15,19];
		if ( exists $clusters->{$gene1}->{$mu1} && exists $clusters->{$gene2}->{$mu2} && $clusters->{$gene1}->{$mu1} eq $clusters->{$gene2}->{$mu2} ) 
		{
			my @infos = split( /\|/ , $info );
			foreach my $dinfo ( @infos ) {
				my ( $dist , $pdb , $pval ) = split( /\s/ , $dinfo );
				my $cluster = $clusters->{$gene1}->{$mu1}; #store clusterid of mutation
				my $best_pdb=$bestStruc->{$cluster}->[1]; #storing best pdb for cluster
				if ($pdb eq $best_pdb){  #if current pdb is equal to pdb 
			#	if ( exists $genesOnPDBref->{$gene1}->{$pdb}#{$chain1} #if PDB structure exists for gene1
			#	&& exists $genesOnPDBref->{$gene2}->{$pdb}#{$chain2} #if PDB structure exists for gene2
#				&& $chain1 eq $chain2 ) { #specific check to mimic SpacePAC restriction
			#	){	
		#			print "pairwise exists in hup file\n"; #debug
				
					print"if statement in pairwise working\n";
					my $rec1=$recurrence->{$cluster}->{$mu1};
					my $rec2=$recurrence->{$cluster}->{$mu2};

					$withinClusterSumDistance{$cluster} += $rec1*$rec2*$dist;
					$mass2pvalues{$cluster}=$pval;
				#	} #if gene,pdb,chain1 exists
				}
			}#foreach dinfo
				
		} #if statement
	} #while pairwise file
	$pairwiseHandle->close();
#	print "got the pairwise info\n";
	return  (\%withinClusterSumDistance,\%mass2pvalues);
}

sub getProx{
	my ($this, $proximity_d, $genesOnPDBref, $uniprotIDs, $AAref, $clusters, $best_pdb) = @_;

	my %distances;
	my $uniprotRef=$uniprotIDs->[0]; #pick 1 uniprot ID to get distances
	my $uni_length=scalar @{$uniprotIDs};
	my $proxFile = $proximity_d.$uniprotRef.".ProximityFile.csv";
#	print "proxfile: $proxFile\n"; #debug
	my $proxHandle = &getFile( $proxFile , "r" );
	my %paircheck;
	my %res_count;

	while(my $line = <$proxHandle>) {
		chomp $line;
#		delete $recurrence{$clusterid};			
		my ( $up1 , $chain1 , $res1 , $aa1 , $up2 , $chain2 , $res2 , $aa2 , $dist , $pdb , $pval ) = (split( /\t/ , $line ))[0..2,4,7..9,11,14..16];
		my $key1="$up1:$res1:$chain1";
		my $key2="$up2:$res2:$chain2";
#		print ("$aa1\t$aa2\t$pdb\t$best_pdb\t$key1\t$key2\n");	
		if (exists $AAref->{$aa1} && exists $AAref->{$aa2} && $pdb eq $best_pdb && !exists $paircheck{$pdb}{$key1}{$key2} && !exists $paircheck{$pdb}{$key2}{$key1}) {
			if(grep $_ eq $up2,@{$uniprotIDs}){ #if 2nd uniprot id is in uniprots that are in cluster
				
				&checkKey($key1,\%res_count,$pdb,\%distances, $uni_length);	
				&checkKey($key2,\%res_count,$pdb,\%distances, $uni_length);	

				push @{$distances{$pdb}} , $dist;
				#print "WE GOT ONE\n";#debug
#				print "2nd if statement working in getProx\n";			
				$paircheck{$pdb}{$key1}{$key2}=1;


			}
		}
	}
		$proxHandle->close();
	return \%distances;

}


sub checkKey{
	my ($key,$res_count,$pdb, $distances,$uni_length)=@_;

	if (! grep $_ eq $key,@{$res_count->{$pdb}}){

		push @{$res_count->{$pdb}}, $key;

		if ($uni_length==1){ #only push 0 distance if it's intramolecular cluster
			push @{$distances->{$pdb}}, 0;
		}
	}

	return 1;
}

sub getDistances{
	my ($this, $proximity_d, $genesOnPDBref, $HUGO2uniprotref, $AAref, $NSIMS, $clusters,$bestStruc, $clus_store, $recurrence, $withinClusterSumDistance,$mass2pvalues) = @_;
	print "getDistances started\n"; #debug
	my $hash_count = keys %$genesOnPDBref;#debug
	my %best_pdb;

	my $fout = $this->{'output_prefix'}.".".$NSIMS."sims.avgDist_pvalue";
	my $OUT = &getFile( $fout , "w" );
	$OUT->print( "Cluster\tGene\tPDB_ID\tNum_Residues\tNum_Mutations\tNum_Pairs\tAvg_Distance\tEstimated_PValue\n" );

	foreach my $clus ( keys %{$clus_store} ) {

		my $best_pdb=$bestStruc->{$clus}->[1]; #store best PDB for cluster
		my @uniprotIDs;
		print "$clus\n";
		foreach my $gene(@{$clus_store->{$clus}}){				
			my $uniprot = $HUGO2uniprotref->{$gene};
			print"$gene\t$uniprot\n";	
			if (! grep $_ eq $uniprot,@uniprotIDs){
				push @uniprotIDs, $uniprot;  #store all unique uniprotIds in cluster
			#	print "$uniprot\n";
				
			}
		}

		#get background distances for cluster 	
		my $distances=$this->getProx($proximity_d, $genesOnPDBref, \@uniprotIDs, $AAref, $clusters, $best_pdb);		
	
		print "printing cluster: $clus\n";
		print "PDB: $best_pdb\n";#debug
		my @distances = sort {$a <=> $b} @{$distances->{$best_pdb}};
		#my @distances = sort {$a <=> $b} keys %{$distances{$pdb}{$chain}};
		my $numDistances = scalar( @distances );

		#print STDOUT $tossedPairs{$pdb}{$chain}." pairs thrown out\n";
		my $genes=join( ":" , @{$clus_store->{$clus}});		
		my %withinClusterAvgDistance;
		my ( $mass , $numPairs, $numResidues );
		$mass=0;
		$numResidues=0;
		foreach my $mut(keys %{$recurrence->{$clus}}){
			my $rec=$recurrence->{$clus}->{$mut};	
			print"$rec\t$mut\n";
			$mass+=$rec;
			$numResidues+=1;
		}

		$numPairs = ( $mass ) * ( $mass - 1 ) / 2;
#		print"distances:@distances\n";					
		if ( $mass > 2 ) {
		
			$withinClusterAvgDistance{$clus} = $withinClusterSumDistance->{$clus} / $numPairs;
#						print "cluster: $cluster, avg distance: $withinClusterAvgDistance{$cluster}, sum distance: $withinClusterSumDistance->{$cluster}\n";#debug
			delete $mass2pvalues->{$clus};
		} elsif ( $mass == 2 ) {
#print STDOUT "Cluster ".$cluster." has ".$mass." residues, so its p-value is ".$mass2pvalues->{$cluster}."\n"; #debug
			$OUT->print( join( "\t" , ( $clus , $genes , $best_pdb , $numResidues, $mass , $numPairs , $withinClusterSumDistance->{$clus} , $mass2pvalues->{$clus} ) )."\n" );
		} elsif ( $mass == 1 ) {
#						print STDOUT "Cluster ".$cluster." has ".$mass." residue, so it has no p-value\n";#debug
			$OUT->print( join( "\t" , ( $clus , $genes , $best_pdb , $numResidues, $mass , $numPairs , 0 , "NA" ) )."\n" );
		} #if mass block

#				print STDOUT $hugo."\t".$pdb."\t".$chain."\n";
		my %below;
#					print STDOUT "Simulation\tSum_Distances\tAvg_Distance\n";
		for ( my $simulation = 0; $simulation < $NSIMS ; $simulation++ ) {
			my $sumDists = 0;
			for ( my $i = 0; $i < $numPairs ; $i++ ) {
				my $randIndex = int( rand( $numDistances ) );
				$sumDists += $distances[$randIndex];
			} #foreach random pick
			my $avgDist = $sumDists / $numPairs;
#						print STDOUT $simulation."\t".$sumDists."\t".$avgDist."\n";
			if ( $avgDist < $withinClusterAvgDistance{$clus} ) {
				$below{$clus}++;
				}
		} #foreach simulation
		my $permutationTestPValue;
		if(exists $below{$clus}){
			$permutationTestPValue = $below{$clus} / $NSIMS;

		#	print " below: $below{$cluster}\t";#debug
		#	print STDOUT "Estimated p-value: ".$permutationTestPValue."\n";
		} else{
			$permutationTestPValue=0;
			print "why zero\n";#debug
		}

		$OUT->print( join( "\t" , ( $clus , $genes , $best_pdb ,$numResidues,$mass , $numPairs , $withinClusterAvgDistance{$clus} , $permutationTestPValue ) )."\n" );
	
	}#foreach cluster
		$OUT->close();
	return 1;
}

sub getFile {
	my ( $file , $rw ) = @_;
#	print "$file\n"; #debug
	my $handle = FileHandle->new( $file, $rw );
	if ( not defined $handle ) {
		if ( $rw eq "w" ) {
			warn "ADSERROR: Could not open/write $file\n";
		} else {
			warn "ADSERROR: Could not open/read $file\n";
		}
		next;
	}
	return $handle;
}

sub help_text{
	my $this = shift;
	return <<HELP

Usage: hotspot3d sigclus [options]

	--prep-dir			Preprocessing directory 
	--pairwise			Pairwise file (pancan19.pairwise)
	--clusters			Cluster file (pancan19.intra.20..05.10.clusters)
	--output			Output file prefix (pancan19.intra.20..05.10)

	--simulations	Number of simulations, default = 1000000

	--help				This message

HELP

}

1;
__DATA__
A	ALA	Alanine
R	ARG	Arginine
N	ASN	Asparagine
D	ASP	Aspartic Acid
C	CYS	Cysteine
E	GLU	Glutamic Acid
Q	GLN	Glutamine
G	GLY	Glycine
H	HIS	Histidine
I	ILE	Isoleucine
L	LEU	Leucine
K	LYS	Lysine
M	MET	Methionine
F	PHE	Phenylalanine
P	PRO	Proline
S	SER	Serine
T	THR	Threonine
W	TRY	Tryptophan
Y	TYR	Tyrosine
V	VAL	Valine
*	S	Stop
