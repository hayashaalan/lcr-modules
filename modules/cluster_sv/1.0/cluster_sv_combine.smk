#!/usr/bin/env snakemake


##### ATTRIBUTION #####


# Original Author:  Cancer IT
# Module Author:    Helena Winata
# Contributors:     N/A


##### SETUP #####


# Import package with useful functions for developing analysis modules
import oncopipe as op

# Check that the oncopipe dependency is up-to-date. Add all the following lines to any module that uses new features in oncopipe
min_oncopipe_version="1.0.11"
import pkg_resources
try:
    from packaging import version
except ModuleNotFoundError:
    sys.exit("The packaging module dependency is missing. Please install it ('pip install packaging') and ensure you are using the most up-to-date oncopipe version")

# To avoid this we need to add the "packaging" module as a dependency for LCR-modules or oncopipe

current_version = pkg_resources.get_distribution("oncopipe").version
if version.parse(current_version) < version.parse(min_oncopipe_version):
    print('\x1b[0;31;40m' + f'ERROR: oncopipe version installed: {current_version}' + '\x1b[0m')
    print('\x1b[0;31;40m' + f"ERROR: This module requires oncopipe version >= {min_oncopipe_version}. Please update oncopipe in your environment" + '\x1b[0m')
    sys.exit("Instructions for updating to the current version of oncopipe are available at https://lcr-modules.readthedocs.io/en/latest/ (use option 2)")

# End of dependency checking section

# Setup module and store module-specific configuration in `CFG`
# `CFG` is a shortcut to `config["lcr-modules"]["cluster_sv"]`
CFG = op.setup_module(
    name = "cluster_sv",
    version = "1.0",
    subdirectories = ["inputs", "reformat_bedpe", "cluster_sv", "outputs"],
)

# Define rules to be run locally when using a compute cluster
localrules:
    _cluster_sv_input_bedpe,
    _cluster_sv_reformat_bedpe,
    _cluster_sv_output_tsv,
    _cluster_sv_all,

# Set cohort name to "ALL" if not defined in config file
if not CFG["options"]["cohort"]:
    CFG["options"]["cohort"] = "ALL"

##### RULES #####

# download cluster files from git repo without cloning the repo itself
# decompress files into the 00-inputs
rule _cluster_sv_install:
    output:
        cluster_sv = CFG["dirs"]["inputs"] + "ClusterSV-" + str(CFG["options"]["cluster_sv_version"]) + "/R/run_cluster_sv.R" # main R script from the repo
    params:
        url = "https://github.com/whelena/ClusterSV/archive/refs/tags/v" + str(CFG["options"]["cluster_sv_version"]) + ".tar.gz",
        folder = CFG["dirs"]["inputs"]
    shell:
        op.as_one_line("""
        wget -qO- {params.url} |
        tar xzf - -C {params.folder}
        """)

# Symlinks the input files into the module results directory (under '00-inputs/')
rule _cluster_sv_input_bedpe:
    input:
        bedpe = CFG["inputs"]["sample_bedpe"]
    output:
        bedpe = CFG["dirs"]["inputs"] + "bedpe/{seq_type}--{genome_build}/{tumour_id}--{normal_id}--{pair_status}.bedpe"
    run:
        op.relative_symlink(input.bedpe, output.bedpe)


# Example variant calling rule (multi-threaded; must be run on compute server/cluster)
rule _cluster_sv_reformat_bedpe:
    input:
        bedpe = str(rules._cluster_sv_input_bedpe.output.bedpe)
    output:
        bedpe = temp(CFG["dirs"]["reformat_bedpe"] + "full_bedpe/{seq_type}--{genome_build}/{tumour_id}--{normal_id}--{pair_status}.bedpe"),
        mapping = CFG["dirs"]["reformat_bedpe"] + "mapping/{seq_type}--{genome_build}/{tumour_id}--{normal_id}--{pair_status}_map.tsv"
    shell:
        op.as_one_line("""
        sed '/^#/d' {input.bedpe} |
        sed -e 's/chr//g' |
        awk -F '\t' 'BEGIN {{OFS="\t"}}; {{print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $15, $18 > "{output.bedpe}"; \
        print "{wildcards.tumour_id}", "{wildcards.normal_id}", $7 > "{output.mapping}" }}' 
        """)


def _cluster_sv_request_bedpe(wildcards):
    CFG = config["lcr-modules"]["cluster_sv"]
    SAMPLES = config["lcr-modules"]["cluster_sv"]["samples"]
    RUNS = config["lcr-modules"]["cluster_sv"]["runs"]

    # if wildcards.cohort != 'ALL':
    if wildcards.cohort in SAMPLES.cohort:
        TUMOURS = SAMPLES.loc[SAMPLES.cohort == wildcards.cohort].sample_id
        RUNS = RUNS.loc[RUNS.tumour_sample_id.isin(TUMOURS)]

    bedpe_files = expand(
        [
            str(rules._cluster_sv_reformat_bedpe.output.bedpe),
        ],
        zip,
        seq_type=RUNS["tumour_seq_type"],
        genome_build=RUNS["tumour_genome_build"],
        tumour_id=RUNS["tumour_sample_id"],
        normal_id=RUNS["normal_sample_id"],
        pair_status=RUNS["pair_status"])

    map_files = expand(
        [
            str(rules._cluster_sv_reformat_bedpe.output.mapping),
        ],
        zip, 
        seq_type=RUNS["tumour_seq_type"],
        genome_build=RUNS["tumour_genome_build"],
        tumour_id=RUNS["tumour_sample_id"],
        normal_id=RUNS["normal_sample_id"],
        pair_status=RUNS["pair_status"])

    return { 'bedpe': bedpe_files, 'mapping': map_files }


rule _cluster_sv_combine_bedpe:
    input:
        unpack(_cluster_sv_request_bedpe)
    output:
        bedpe = CFG["dirs"]["reformat_bedpe"] + "combined/{seq_type}--{genome_build}/{cohort}_combined.bedpe",
        mapping = CFG["dirs"]["reformat_bedpe"] + "combined/{seq_type}--{genome_build}/{cohort}_map.tsv"
    shell:
        op.as_one_line("""
        cat {input.bedpe} > {output.bedpe} &&
        cat {input.mapping} > {output.mapping} &&
        sed -i '1i #CHROM_A\tSTART_A\tEND_A\tCHROM_B\tSTART_B\tEND_B\tID\tQUAL\tSTRAND_A\tSTRAND_B\tALT_A\tALT_B' {output.bedpe} &&
        sed -i '1i #tumour_id\tnormal_id\tSV_id' {output.mapping}
        """)


rule _cluster_sv_all:
    input:
        expand(
            [
                str(rules._cluster_sv_combine_bedpe.output.bedpe),
                str(rules._cluster_sv_combine_bedpe.output.mapping)
            ],
            zip,  # Run expand() with zip(), not product()
            seq_type=CFG["runs"]["tumour_seq_type"],
            genome_build=CFG["runs"]["tumour_genome_build"],
            cohort=CFG["options"]["cohort"])


##### CLEANUP #####


# Perform some clean-up tasks, including storing the module-specific
# configuration on disk and deleting the `CFG` variable
op.cleanup_module(CFG)
