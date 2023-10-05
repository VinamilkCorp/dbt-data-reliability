{% macro sql_union_distinct() %}
union {% if target.type == "bigquery" or target.type == "clickhouse" %} distinct {% endif %}
{% endmacro %}
