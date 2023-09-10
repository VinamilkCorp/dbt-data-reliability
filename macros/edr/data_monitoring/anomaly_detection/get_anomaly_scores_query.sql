{% macro get_anomaly_scores_query(test_metrics_table_relation, model_relation, test_configuration, monitors, column_name = none, columns_only = false, metric_properties = none, data_monitoring_metrics_table=none) %}
    {%- set model_graph_node = elementary.get_model_graph_node(model_relation) %}
    {%- set full_table_name = elementary.model_node_to_full_name(model_graph_node) %}
    {%- set test_execution_id = elementary.get_test_execution_id() %}
    {%- set test_unique_id = elementary.get_test_unique_id() %}
    {%- if not data_monitoring_metrics_table %}
        {#  data_monitoring_metrics_table is none except for integration-tests that test the get_anomaly_scores_query macro,
          and in which case it holds mock history metrics #}
          {%- set data_monitoring_metrics_table = ref('data_monitoring_metrics') %}
    {%- endif %}


    {%- if elementary.is_incremental_model(model_graph_node) %}
      {%- set latest_full_refresh = elementary.get_latest_full_refresh(model_graph_node) %}
    {%- else %}
      {%- set latest_full_refresh = none %}
    {%- endif %}

    {%- if test_configuration.seasonality == 'day_of_week' %}
        {%- set bucket_seasonality_expr = elementary.edr_day_of_week_expression('bucket_end') %}

    {%- elif test_configuration.seasonality == 'hour_of_day' %}
        {%- set bucket_seasonality_expr = elementary.edr_hour_of_day_expression('bucket_end') %}

    {%- elif test_configuration.seasonality == 'hour_of_week' %}
        {%- set bucket_seasonality_expr = elementary.edr_hour_of_week_expression('bucket_end') %}

    {%- else %}
        {%- set bucket_seasonality_expr = elementary.const_as_text('no_seasonality') %}
    {%- endif %}
    {%- set min_bucket_start_expr = elementary.get_trunc_min_bucket_start_expr(metric_properties, test_configuration.days_back) %}

    {%- set anomaly_scores_query %}

        with data_monitoring_metrics as (

            select
                id,
                full_table_name,
                column_name,
                metric_name,
                metric_value,
                source_value,
                bucket_start,
                bucket_end,
                bucket_duration_hours,
                updated_at,
                dimension,
                dimension_value,
                metric_properties
            from {{ data_monitoring_metrics_table }}
            {# We use bucket_end because non-timestamp tests have only bucket_end field. #}
            where
                bucket_end > {{ min_bucket_start_expr }}
                and metric_properties = {{ elementary.dict_to_quoted_json(metric_properties) }}
                {% if latest_full_refresh %}
                    and updated_at > {{ elementary.edr_cast_as_timestamp(elementary.edr_quote(latest_full_refresh)) }}
                {% endif %}
                and upper(full_table_name) = upper('{{ full_table_name }}')
                and metric_name in {{ elementary.strings_list_to_tuple(monitors) }}
                {%- if column_name %}
                    and upper(column_name) = upper('{{ column_name }}')
                {%- endif %}
                {%- if columns_only %}
                    and column_name is not null
                {%- endif %}
                {% if test_configuration.dimensions %}
                    and dimension = {{ elementary.edr_quote(elementary.join_list(test_configuration.dimensions, '; ')) }}
                {% endif %}
        ),

        union_metrics as (

            select * from data_monitoring_metrics
            union all
            select * from {{ test_metrics_table_relation }}

        ),

        grouped_metrics_duplicates as (

            select
                id,
                full_table_name,
                column_name,
                metric_name,
                metric_value,
                source_value,
                bucket_start,
                bucket_end,
                bucket_duration_hours,
                updated_at,
                dimension,
                dimension_value,
                row_number() over (partition by id order by updated_at desc) as row_number
            from union_metrics

        ),

        grouped_metrics as (

            select
                id as metric_id,
                full_table_name,
                column_name,
                dimension,
                dimension_value,
                metric_name,
                metric_value,
                source_value,
                bucket_start,
                bucket_end,
                {{ bucket_seasonality_expr }} as bucket_seasonality,
                bucket_duration_hours,
                updated_at
            from grouped_metrics_duplicates
            where row_number = 1

        ),

        time_window_aggregation as (

            select
                metric_id,
                full_table_name,
                column_name,
                dimension,
                dimension_value,
                metric_name,
                metric_value,
                source_value,
                bucket_start,
                bucket_end,
                bucket_seasonality,
                bucket_duration_hours,
                updated_at,
                avg(metric_value) over (partition by metric_name, full_table_name, column_name, dimension, dimension_value, bucket_seasonality order by bucket_end asc rows between unbounded preceding and current row) as training_avg,
                stddev(metric_value) over (partition by metric_name, full_table_name, column_name, dimension, dimension_value, bucket_seasonality order by bucket_end asc rows between unbounded preceding and current row) as training_stddev,
                count(metric_value) over (partition by metric_name, full_table_name, column_name, dimension, dimension_value, bucket_seasonality order by bucket_end asc rows between unbounded preceding and current row) as training_set_size,
                last_value(bucket_end) over (partition by metric_name, full_table_name, column_name, dimension, dimension_value, bucket_seasonality order by bucket_end asc rows between unbounded preceding and current row) training_end,
                first_value(bucket_end) over (partition by metric_name, full_table_name, column_name, dimension, dimension_value, bucket_seasonality order by bucket_end asc rows between unbounded preceding and current row) as training_start
            from grouped_metrics
            {{ dbt_utils.group_by(13) }}
        ),

        percentiles as (
            select
                metric_id,
                percent_rank() 
                    over (
                        partition by metric_name, full_table_name, column_name, dimension, dimension_value, bucket_seasonality
                        order by metric_value range between unbounded preceding and current row
                    )
                as training_percentile
            from (
                select
                    *
                from time_window_aggregation
                order by bucket_end
            )
        ),

        time_window_aggregation_with_percentiles as (
            select 
                * 
            from time_window_aggregation
            join percentiles 
            using(metric_id)
        ),

        anomaly_scores as (

            select
                {{ elementary.generate_surrogate_key([
                 'metric_id',
                 elementary.const_as_string(test_execution_id)
                ]) }} as id,
                metric_id,
                {{ elementary.const_as_string(test_execution_id) }} as test_execution_id,
                {{ elementary.const_as_string(test_unique_id) }} as test_unique_id,
                {{ elementary.current_timestamp_column() }} as detected_at,
                full_table_name,
                column_name,
                metric_name,
                case
                    when training_stddev is null then null
                    when training_stddev = 0 then 0
                    else (metric_value - training_avg) / (training_stddev)
                end as anomaly_score,
                {{ test_configuration.anomaly_sensitivity }} as anomaly_score_threshold,
                source_value as anomalous_value,
                bucket_start,
                bucket_end,
                bucket_seasonality,
                metric_value,
                {% set min_metric_value_expr %}
                    ((-1) * {{ test_configuration.anomaly_sensitivity }} * training_stddev + training_avg)
                {% endset %}
                case
                    when training_stddev is null then null
                    when {{ min_metric_value_expr }} > 0 or metric_name in {{ elementary.to_sql_list(elementary.get_negative_value_supported_metrics()) }} then {{ min_metric_value_expr }}
                    else 0
                end as min_metric_value,
                case 
                    when training_stddev is null then null
                    else {{ test_configuration.anomaly_sensitivity }} * training_stddev + training_avg
                end as max_metric_value,
                training_avg,
                training_stddev,
                training_percentile,
                training_set_size,
                training_start,
                training_end,
                dimension,
                dimension_value
            from time_window_aggregation_with_percentiles
            where
                metric_value is not null
                and training_avg is not null
        )

        select * from anomaly_scores

    {% endset %}
    {{ return(anomaly_scores_query) }}
{% endmacro %}

{% macro get_negative_value_supported_metrics() %}
    {% do return(["min", "max", "average", "standard_deviation", "variance", "sum"]) %}
{% endmacro %}
