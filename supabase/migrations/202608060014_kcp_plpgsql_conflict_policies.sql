begin;

-- PostgreSQL correctly reports ambiguous PL/pgSQL names when a local variable
-- or RETURNS TABLE output has the same name as a table column. These three
-- existing functions predate the stricter CI lint step. Recompile them with an
-- explicit, function-scoped policy so their intended references are clear:
--
-- - invitation ON CONFLICT targets are table columns
-- - calendar_id in the schedule generators is the local UUID variable
--
-- The directive is documented by PostgreSQL and affects only the function in
-- which it appears.
do $$
declare
    target record;
    definition text;
    rewritten text;
begin
    for target in
        select *
        from (values
            ('public.kcp_accept_invitation(text,text,text)'::regprocedure, 'use_column'::text),
            ('public.kcp_generate_fixed_schedule(uuid,text)'::regprocedure, 'use_variable'::text),
            ('public.kcp_generate_balanced_schedule(uuid,text)'::regprocedure, 'use_variable'::text)
        ) as requested(function_oid, conflict_policy)
    loop
        definition := pg_get_functiondef(target.function_oid);
        rewritten := regexp_replace(
            definition,
            'AS \$function\$[[:space:]]*',
            'AS $function$' || E'\n#variable_conflict ' || target.conflict_policy || E'\n',
            1,
            1,
            'i'
        );

        if rewritten = definition
           or position('#variable_conflict ' || target.conflict_policy in rewritten) = 0 then
            raise exception 'Could not apply conflict policy % to %',
                target.conflict_policy,
                target.function_oid;
        end if;

        execute rewritten;
    end loop;
end;
$$;

-- Verify that all three stored function bodies include the intended policy.
do $$
begin
    if position(
        '#variable_conflict use_column'
        in (select prosrc from pg_proc where oid = 'public.kcp_accept_invitation(text,text,text)'::regprocedure)
    ) = 0 then
        raise exception 'Invitation conflict policy was not stored';
    end if;

    if position(
        '#variable_conflict use_variable'
        in (select prosrc from pg_proc where oid = 'public.kcp_generate_fixed_schedule(uuid,text)'::regprocedure)
    ) = 0 then
        raise exception 'Fixed schedule conflict policy was not stored';
    end if;

    if position(
        '#variable_conflict use_variable'
        in (select prosrc from pg_proc where oid = 'public.kcp_generate_balanced_schedule(uuid,text)'::regprocedure)
    ) = 0 then
        raise exception 'Balanced schedule conflict policy was not stored';
    end if;
end;
$$;

commit;
