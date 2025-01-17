package RASTTestUtils;

use Test::Most;
use strict;
use warnings;
use feature qw( say );
use Data::Dumper::Concise;
use Data::UUID;

use JSON;
use File::Copy;

use installed_clients::WorkspaceClient;
use installed_clients::AssemblyUtilClient;
use installed_clients::GenomeFileUtilClient;
use installed_clients::kb_SetUtilitiesClient;

local $| = 1;
my $token        = $ENV{ 'KB_AUTH_TOKEN' };
my $config_file  = $ENV{ 'KB_DEPLOYMENT_CONFIG' };
my $callback_url = $ENV{ 'SDK_CALLBACK_URL' };

my $config       = Config::Simple->new( $config_file )->get_block( 'RAST_SDK' );
my $ws_url       = $config->{ "workspace-url" };
my ( $ws_name, $ws_client, $ws_id );

my $call_back_url = $ENV{ SDK_CALLBACK_URL };
my ( $au, $gfu, $su );

my $base_dir = '/kb/module/';

sub get_ws_client {
    $ws_client //= installed_clients::WorkspaceClient->new( $ws_url, token => $token );
    return $ws_client;
}

sub set_ws {
    my ($name_or_id) = @_;
    if (!defined($ws_client)) {
    	get_ws_client();	
    }
    if ($name_or_id =~ m/^\d+$/) {
    	$ws_id = $name_or_id+0;
    	my $info = $ws_client->get_workspace_info({id=>$ws_id});
    	$ws_name = $info->[1];
    } else {
    	$ws_name = $name_or_id;
    	my $info = $ws_client->get_workspace_info({workspace=>$ws_name});
    	$ws_id = $info->[0];
    }   
}

sub get_ws_id {
    unless ( $ws_id ) {
        get_ws_name();
    }
    return $ws_id;
}

sub get_ws_name {
    unless ( $ws_name ) {
        $ws_client = get_ws_client();
        my $suffix = Data::UUID->new()->create_str();
        $ws_name = 'test_RAST_SDK_' . $suffix;
        my $resp = $ws_client->create_workspace( { workspace => $ws_name } );
        $ws_id = $resp->[ 0 ];
    }
    return $ws_name;
}

sub get_setutils_client {
    $su //= installed_clients::kb_SetUtilitiesClient->new( $callback_url );
}

sub get_genome_file_util_client {
    $gfu //= installed_clients::GenomeFileUtilClient->new( $call_back_url );
}

#--------------------------------------------
#	Call the RAST annotation Impl file
#	Create a JSON object of the parameters and submit
#--------------------------------------------
sub make_impl_call {
    my ($method, $params) = @_;
    # Prepare json file input
    my $input = {
        method => $method,
        params => $params,
        version => "1.1",
        id => "1"
    };
    open my $fh, ">", "/kb/module/work/input.json";
    print $fh encode_json($input);
    close $fh;
    my $output_path = "/kb/module/work/output.json";
    if (-e $output_path) {
        unlink($output_path);
    }
    # Run run_async.sh
    system("sh", "/kb/module/scripts/run_async.sh");
    # Load json file with output
    unless (-e $output_path) {
        die "Output file of JSON-RPC call (in CLI mode) wasn't created";
    }
    open my $fh2, "<", $output_path;
    my $output_json = <$fh2>;
    close $fh2;
    my $json = JSON->new;
    my $output = $json->decode($output_json);
    if (defined($output->{error})) {
        die encode_json($output->{error});
    }
    my $ret_obj = $output->{result}->[0];
    return ($ret_obj);
}

#--------------------------------------------
#	Copy FASTA file to workspace and
#	use AFU to create the assembly object and assembly reference
#--------------------------------------------
sub prepare_assembly {
    my($assembly_obj_name) = @_;
    #my $fasta_data_path = "/kb/module/test/data/Clostridium_thermocellum_ATCC27405.fa";
    my $fasta_data_path = "/kb/module/test/data/$assembly_obj_name";
    my $fasta_temp_path = "/kb/module/work/tmp/$assembly_obj_name";
    copy $fasta_data_path, $fasta_temp_path;
    $au                 //= installed_clients::AssemblyUtilClient->new( $call_back_url );
    my $ret             = $au->save_assembly_from_fasta( {
        file            => { path => $fasta_temp_path },
        workspace_name => get_ws_name(),
        assembly_name => $assembly_obj_name
    } );
    unlink($fasta_temp_path);
    return $ret;
}

#--------------------------------------------
#	Copy Genbank file to workspace and
#	use GFU to create the genome object and genome reference
#--------------------------------------------
sub prepare_gbff {
    my ( $genome_gbff_name, $genome_obj_name ) = @_;
    $gfu                 //= installed_clients::GenomeFileUtilClient->new( $call_back_url );
	my $genome_gbff_path = "/kb/module/test/data/$genome_gbff_name";
	my $temp_path = "/kb/module/work/tmp/$genome_gbff_name";
	copy $genome_gbff_path, $temp_path;

    say "***** Loading and Saving the Genome Object *****";
    my $genome_obj = $gfu->genbank_to_genome( {
		workspace_name => get_ws_name(),
		genome_name => $genome_obj_name,
		file => {"path" => $temp_path},
		source => "Refseq"
	});
#	print "Genome Object Keys\n";
#	foreach my $key (keys(%$genome_obj))
#	{
#		print "\t$key ".ref($genome_obj->{$key})." \n";
#	}
	my $genome_ref = $genome_obj->{'genome_ref'};
	return ($genome_obj, $genome_ref);
}

sub get_genome {
	my $genome_ref = shift;
	my $orig_genome = $ws_client->get_objects([{ref=>$genome_ref}])->[0]->{data};

    if (defined($orig_genome->{taxon_ref})) {
        $orig_genome->{taxon_ref} = "ReferenceTaxons/unknown_taxon" ;
    }
    if (defined($orig_genome->{genbank_handle_ref})) {
        delete $orig_genome->{genbank_handle_ref};
    }

	if (! exists $orig_genome->{features}) {
		$orig_genome->{features} = [];
	}
	if (! exists $orig_genome->{non_coding_features}) {
		$orig_genome->{non_coding_features} = [];
	}
	return $orig_genome;
}

#
#	Summarize the features in the input genome
#
sub summarize_input {
	my $orig_genome = shift;
	my $orig_funcs = {};
	my %types;

##  Features
	for (my $i=0; $i < scalar @{$orig_genome->{features}}; $i++) {
		my $ftr = $orig_genome->{features}->[$i];
		if (defined($ftr->{functions}) && scalar @{$ftr->{functions}} > 0){
					$ftr->{function} = join("; ", @{$ftr->{functions}});
		}
		my $func      = defined($ftr->{function}) ? $ftr->{function} : "";
		$orig_funcs->{$ftr->{id}} = $func;
		if (not defined($ftr->{type})) {
			if (defined($ftr->{protein_translation})) {
				$ftr->{type} = "gene";
			} else {
				$ftr->{type} = "other";
			}
		}
		if ($ftr->{type} eq "gene" and not(defined($ftr->{protein_translation}))) {
			if (lc($func) =~ /ribosomal/) {
				$ftr->{type} = 'rRNA';
			}
			elsif (lc($func) =~ /trna/) {
				$ftr->{type} = 'tRNA';
			} else {
				$ftr->{type} = 'other non-coding';
			}
		}
		$ftr->{type} = "other" if not defined($ftr->{type});
		%types = &count_types($ftr->{type},%types);
    }
##  Noncoding
	for (my $i=0; $i < scalar @{$orig_genome->{non_coding_features}}; $i++) {
		my $ftr = $orig_genome->{non_coding_features}->[$i];
		if (defined($ftr->{functions}) && scalar @{$ftr->{functions}} > 0){
					$ftr->{function} = join("; ", @{$ftr->{functions}});
		}
        my $func      = defined($ftr->{function}) ? $ftr->{function} : "";
        $orig_funcs->{$ftr->{id}} = $func;
		if (not defined($ftr->{type})) {
           if (defined($ftr->{protein_translation})) {
              $ftr->{type} = "gene";
           } else {
              $ftr->{type} = "other";
           }
		}
		%types = &count_types($ftr->{type},%types);
    }
	&report_types(%types);
	return ($orig_funcs);

}

sub count_types {
	my ($feat_type,%types) = @_;

	if (exists $types{$feat_type}) {
		$types{$feat_type} ++;
	} else {
		$types{$feat_type} = 1;
	}
	return %types;
}

sub report_types {
    my %types = @_;
    say 'Summary of input type: ' . Dumper \%types;
}

sub set_params {
	my($genome_obj_name, $params) = @_;
	my $default_params={
             "call_features_rRNA_SEED"=>'0',
             "call_features_tRNA_trnascan"=>'0',
             "call_selenoproteins"=>'0',
             "call_pyrrolysoproteins"=>'0',
             "call_features_repeat_region_SEED"=>'0',
             "call_features_insertion_sequences"=>'0',
             "call_features_strep_suis_repeat"=>'0',
             "call_features_strep_pneumo_repeat"=>'0',
             "call_features_crispr"=>'0',
             "call_features_CDS_glimmer3"=>'0',
             "call_features_CDS_prodigal"=>'0',
             "annotate_proteins_kmer_v2"=>'0',
             "kmer_v1_parameters"=>'0',
             "annotate_proteins_similarity"=>'0',
             "retain_old_anno_for_hypotheticals"=>'0',
             "resolve_overlapping_features"=>'0',
             "call_features_prophage_phispy"=>'0',
             "output_genome"=>$genome_obj_name,
             "workspace"=>get_ws_name()
           };
	foreach my $key (keys %$default_params) {
		unless (exists $params->{$key}) {
			$params->{$key} = $default_params->{$key};
		}
	}
	return $params;
}

sub submit_annotation {
	my ($genome_obj_name, $genome_ref,$params) = @_;
	$params = &set_params($genome_obj_name, $params);
	my $ret = &make_impl_call("RAST_SDK.annotate_genome", $params);

	my $report_ref = $ret->{report_ref};
	my $report_obj = $ws_client->get_objects([{ref=>$report_ref}])->[0]->{data};
	my $report_text = $report_obj->{direct_html};
	print "\nReport: " . $report_text . "\n\n";
	$genome_ref = get_ws_name() . "/" . $genome_obj_name ;
	my $genome_obj = $ws_client->get_objects([{ref=>$genome_ref}])->[0]->{data};

	if (! exists $genome_obj->{features}) {
		$genome_obj->{features} = [];
	}
	if (! exists $genome_obj->{non_coding_features}) {
		$genome_obj->{non_coding_features} = [];
	}
	return ($genome_obj,$params);
}

sub submit_set_annotation {
	my ($params) = @_;
	$params = &set_params($params->{output_genome}, $params);
	my $ret = &make_impl_call("RAST_SDK.annotate_genomes", $params);
	my $report_ref = $ret->{report_ref};
	my $report_obj = $ws_client->get_objects([{ref=>$report_ref}])->[0]->{data};
	my $report_text = $report_obj->{direct_html} || '';
	print "\nReport: " . $report_text . "\n\n";
	my $ref = get_ws_name() . "/" . $params->{output_genome} ;
	my $genome_objs = $ws_client->get_objects([{ref=>$ref}])->[0]->{data}->{elements};
	foreach my $obj (keys %$genome_objs) {
		my $name = $ws_client->get_object_info([{ref=>$obj}],0)->[0]->[1];
	}
	return ($ref);
}

sub clean_up {
    if ( $ws_name ) {
        lives_ok {
            $ws_client->delete_workspace({workspace => $ws_name});
        }, 'Test workspace successfully deleted';
    }
}

sub files_with_ext {
    my ( $tester, $regex, @dirs ) = @_;

    @dirs = @dirs ? @dirs : ( $base_dir );

    my @files;
    for my $file ( $tester->_find_files( @dirs ) ) {
        push @files, $file if $file =~ $regex;
    }
    return @files;
}

1;
