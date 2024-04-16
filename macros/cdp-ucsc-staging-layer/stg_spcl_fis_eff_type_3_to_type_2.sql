{# dbt run-operation --quiet stg_spcl_fis_eff_type_3_to_type_2 --args '{"source_name": "fis", "table_name": "frrbasi", "alphabetize": true}' #}

{% macro stg_spcl_fis_eff_type_3_to_type_2(source_name, table_name, partition_columns, alphabetize=true) %}

{# GET ALL COLUMNS FROM SOURCE TABLE (this information comes from the database)#}
{%- set source_relation = source(source_name, table_name) -%}
{%- set columns = adapter.get_columns_in_relation(source_relation) -%}

{# CONDITIONAL ALPHABETIZATION OF THE LOWER CASED COLUMN LIST #}
{% if alphabetize %}
    {%- set col_names = columns | map(attribute='name') | map('lower') | sort -%}
{% else %}
    {%- set col_names = columns | map(attribute='name') | map('lower') | list -%}
{% endif %}

{# DECLARE EMPTY VARIABLES THAT WILL STORE COLUMN META INFORMATION FROM THE MANIFEST.JSON #}
{% set ns = namespace() %} {# Use namespace so ns.eff_col can persist outside of the for loop it is defined in #}
{%- set ns.eff_col = "" -%}
{%- set ns.eff_col_renamed_as = "" -%}
{%- set partition_cols = [] -%}
{%- set partition_cols_renamed_as = [] -%}
{%- set col_casted_as =  {} -%}
{%- set col_renamed_as = {} -%}
{%- set soft_delete_cols = [] -%}

{# USE GRAPH CONTEXT VARIABLE TO GET TABLE INFORMATION FROM THE MANIFEST.JSON WHICH REFLECTS PROP. AND CONFIG. DECLARATIONS IN THE SOURCE.YML #}
{%- for table_attributes in graph.sources.values() | selectattr("name", "equalto", table_name) -%}
    {# GET THE MODEL'S EFFECTIVE DATE COLUMN FROM THE GRAPH CONTEXT VARIABLE #}
    {% set ns.eff_col = table_attributes.meta.effective_date_col %}

    {# GET THE MODEL'S PARTITION COLUMNS FROM THE GRAPH CONTEXT VARIABLE #}
    {% for i in table_attributes.meta.partition_columns %}
    {% do partition_cols.append(i) %}
    {% endfor %}

    {# GET COLUMN AND COLUMN INFORMATION FROM THE GRAPH CONTEXT VARIABLE #}
    {%- for col, col_attr in table_attributes.columns | items -%}
        {# (1) IF THERE IS A RENAMED_AS VALUE DECLARED UNDER META, CREATE A DICTIONARY WITH THE COLUMN AND VALUE #}
        {%- if col_attr.meta.renamed_as %}
            {% do col_renamed_as.update ({col : col_attr.meta.renamed_as}) %}
        {%- endif %}
        {# (2) IF THERE IS A CASTED_AS VALUE DECLARED UNDER META, CREATE A DICTION WITH THE COLUMN AND VALUE #}
        {%- if col_attr.meta.casted_as %}
            {% do col_casted_as.update ({col : col_attr.meta.casted_as}) %}
        {%- endif %}
    {%- endfor -%}

    {# GET THE SOFT DELETE TRACKING COLUMNS AND THEIR CONDITIONS #}
    {% for i in table_attributes.source_meta.soft_delete_columns %}
    {% do soft_delete_cols.append(i) %}
    {% endfor %}

{%- endfor %}

{# FIELDS THAT NEED TO BE REFERENCED DIRECTLY THAT ARE DOWNSTREAM FROM THE TRANSFORMATION CTE NEED TO BE REFERRED TO USING THEIR NEW NAMES. THESE RENAMED VARIABLES OF THE THE ORIGINAL VARIABLES WILL BE USED IN ANY CTE AFTER THE TRANSFORMATION CTE. #}
{%- if col_renamed_as[ns.eff_col] -%}
{%- set ns.eff_col_renamed_as = col_renamed_as[ns.eff_col] -%}
{%- else -%}
{%- set ns.eff_col_renamed_as = ns.eff_col -%}
{%- endif -%}

{%- for i in partition_cols -%}
{%- if col_renamed_as[i] -%}
{%- do partition_cols_renamed_as.append(col_renamed_as[i]) -%}
{%- else -%}
{%- do partition_cols_renamed_as.append(i) -%}
{%- endif -%}
{%- endfor -%}

{%- set stg_spcl_fis_eff_type_3_to_type_2 -%}
/*  The partition columns are: {{partition_cols}}
*/

with
    source as (
        select * from {% raw -%} {{ source( {%- endraw -%} '{{ source_name }}', '{{ table_name }}' {%- raw -%} ) }}{% endraw %}
        {%- if soft_delete_cols[0] %}
        where
            {{ soft_delete_cols | join('\nand ') | indent(12) }}
        {%- endif %}
    ),

    derive_effseq_and_transform as (
        -- Derive a sequence number for records that share the same effective day
        select
        {%- for i in col_names %}
            {# (0) KEEP ORIGINAL TIMESTAMP EFF DATE COLUMN AND CAST TO DATE #}
            {%- if i == ns.eff_col -%}
            {{i}} as {{i}}_timestamp,
            cast({{i}} as date) as {{i}},
            {# (1) CAST AND RENAME #}
            {%- elif col_casted_as[i] and col_renamed_as[i] -%}
            cast({{i}} as {{col_casted_as[i]}}) as {{col_renamed_as[i]}},
            {#- (2) CAST ONLY #}
            {%- elif col_casted_as[i] and not col_renamed_as[i] -%}
            cast({{i}} as {{col_casted_as[i]}}) as {{i}},
            {#- (3) RENAME ONLY #}
            {%- elif not col_casted_as[i] and col_renamed_as[i] -%}
            {{i}} as {{col_renamed_as[i]}},
            {#- (4) NO TRANSFORMATION #}
            {%- else -%}
            {{i}},
            {%- endif -%}
        {%- endfor %}

            row_number() over (
                partition by
                    {{ partition_cols | join(',\n') | indent(20) }},
                    cast({{ns.eff_col}} as date)

                order by
                    {{ns.eff_col}} desc,
                    {{table_name}}_nchg_date desc
            ) as {{table_name}}_effseq

        from source
    ),

    valid_to as (
        -- Group the records so that each group belonging to one effdt gets the same valid_to date
        select
            {{ partition_cols_renamed_as | join(',\n') | indent(12) }},
            {{ns.eff_col_renamed_as}},
            coalesce((lag({{ns.eff_col_renamed_as}}, 1) over (
                partition by
                    {{ partition_cols_renamed_as | join(',\n') | indent(20) }}
                order by {{ns.eff_col_renamed_as}} desc
            ) - 1), '2099-12-31') as valid_to

        from derive_effseq_and_transform
        group by
            {% for i in partition_cols_renamed_as -%}
                            {{loop.index}},
            {{loop.index + 1 if loop.last }}
            {%- endfor %}
    ),

    final as (
        select
            derive_effseq_and_transform.*,

            -- New Objects
            derive_effseq_and_transform.{{ns.eff_col_renamed_as}} as valid_from,
            derive_effseq_and_transform.{{table_name}}_effseq = 1 as is_latter_rcd_of_effdt,
            case
                when is_latter_rcd_of_effdt = true then valid_to.valid_to
                else derive_effseq_and_transform.{{ns.eff_col_renamed_as}}
            end as valid_to,
            case
                when valid_from > {{'{{'}} var("current_date_pst") {{'}}'}} then 'future'
                when valid_to.valid_to < {{'{{'}} var("current_date_pst") {{'}}'}} then 'past'
                when valid_to.valid_to >= {{'{{'}} var("current_date_pst") {{'}}'}}
                    and is_latter_rcd_of_effdt = true
                    then 'current'
                when valid_to.valid_to >= {{'{{'}} var("current_date_pst") {{'}}'}}
                    and is_latter_rcd_of_effdt = false
                    then 'past'
            end as current_record_desc,
            case
                when current_record_desc = 'current' then true
                when current_record_desc in ('future', 'past') then false
            end as is_current_record

        from derive_effseq_and_transform

        left outer join valid_to
            {% for i in partition_cols_renamed_as -%}
            {{'on' if loop.first else '\n                and'}} derive_effseq_and_transform.{{i}} = valid_to.{{i}}{% endfor %}
                and derive_effseq_and_transform.{{ns.eff_col_renamed_as}} = valid_to.{{ns.eff_col_renamed_as}}
    )

select * from final
where is_latter_rcd_of_effdt = true
{%- endset -%}


{%- if execute -%}
    {{ print(stg_spcl_fis_eff_type_3_to_type_2) }}
    {%- do return(stg_spcl_fis_eff_type_3_to_type_2) -%}
{%- endif -%}

{%- endmacro -%}
