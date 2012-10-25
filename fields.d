module dpq2.fields;

import dpq2.answer;
import dpq2.libpq;
import std.string;

struct Field( T, string sqlName, string sqlPrefix = "", string decl = "" )
{
    alias T type;
    
    static string toString() pure nothrow
    {
        return "\""~( sqlPrefix.length ? sqlPrefix~"."~sqlName : sqlName )~"\"";
    }
    
    static string toDecl() pure nothrow
    {
        return decl.length ? decl : (sqlPrefix.length ? sqlPrefix~"_"~sqlName : sqlName);
    }
    
    static string toRowProperty(size_t column)
    {
        return "@property "~to!string(typeid(T))~" "~toDecl()~"()"
            "{ return (*row)["~to!string(column)~"].as!("~to!string(typeid(T))~"); }";
    }
}

struct Fields( TL ... )
{
    private static string joinFieldString( string memberName )( string delimiter )
    {
        string r;
        foreach( i, T; TL )
        {
            mixin( "r ~= T." ~ memberName ~ ";" );
            if( i < TL.length-1 ) r ~= delimiter;
        }
        
        return r;
    }
    
    @property
    static string toString() nothrow
    {
        return joinFieldString!("toString()")(", ");
    }
    
    private static string GenFieldsEnum() nothrow
    {
        return joinFieldString!("toDecl()")(", ");
    }
    
    mixin("enum FieldsEnum {"~GenFieldsEnum()~"}");
    alias FieldsEnum this;    
}

struct RowFields( TL ... )
{
    Fields!(TL) fields;
    alias fields this;
    
    Row* row;
    
    @property
    void answer( ref Row r )
    {
        row = &r;
    }
    
    @property PGtext FIELD_NAME()
    {
        return (*row)[ 0 ].as!(PGtext);
    }
    
    @property
    auto getVal(fields.FieldsEnum e)()
    {
        return row.opIndex(e).as!( TL[e].type );
    }
    
    /*
    private string GenProperties()
    {
        return joinFieldString!(")
    */
}

void _unittest( string connParam )
{
    auto conn = new Connection;
	conn.connString = connParam;
    conn.connect();
    
    RowFields!( Field!(PGtext, "i", "", "INT" ), Field!(PGtext, "t") ) f;
    
    string q = "select "~to!string(f)~"
        from (select 123::integer as i, 'qwerty'::text as t) s";
    auto res = conn.exec( q );
    
    import std.stdio;
    writeln( f.toString() );
    writeln( f.INT );
    writeln( res );
    
    writeln( res[0,1].as!PGtext );
    
    foreach( r; res )
    {
        f.answer = r;
        writeln( r[f.INT].as!PGtext );
        writeln( f.getVal!(f.INT) );
    }
}
