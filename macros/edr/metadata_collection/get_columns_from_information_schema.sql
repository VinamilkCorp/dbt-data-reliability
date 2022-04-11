{% macro get_columns_from_information_schema(full_schema_name) %}
    {{ return(adapter.dispatch('get_columns_from_information_schema', 'elementary')(full_schema_name)) }}
{% endmacro %}

{# Snowflake, Bigquery, Redshift #}
{% macro default__get_columns_from_information_schema(full_schema_name) %}
    {% set full_schema_name_split = full_schema_name.split('.') %}
    {% set database_name = full_schema_name_split[0] %}
    {% set schema_name = full_schema_name_split[1] %}
    {% set schema_name_string = schema_name | replace('"','') %}

    select
        upper(table_catalog || '.' || table_schema || '.' || table_name) as full_table_name,
        upper(table_catalog) as database_name,
        upper(table_schema) as schema_name,
        upper(table_name) as table_name,
        upper(column_name) as column_name,
        data_type
    from  {{ elementary.from_information_schema('COLUMNS', database_name, schema_name) }}
    where upper(table_schema) = upper('{{ schema_name_string }}')

{% endmacro %}