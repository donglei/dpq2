module dpq2.fields;

import dpq2.answer;

string addQuotes(string s) pure nothrow { return "\""~s~"\""; }    

struct Field( string sqlName, string sqlPrefix = "", string decl = "" )
{
    static string sql() pure nothrow
    {
        return "\""~( sqlPrefix.length ? sqlPrefix~"\".\""~sqlName : sqlName )~"\"";
    }
    
    static string toDecl() pure nothrow
    {
        return decl.length ? decl : sqlName;
    }
    
    alias toDecl toTemplatedName;
    
    static string toArrayElement() pure nothrow
    {
        return addQuotes( toDecl() );
    }
}

alias Field QueryField;

struct ResultField( T, string sqlName, string sqlPrefix = "", string decl = "", string PGtypeCast = "" )
{
    alias T type;
    Field!(sqlName, sqlPrefix, decl) field;
    alias field this;
    
    static string sql() nothrow
    {
        return field.sql() ~ ( PGtypeCast.length ? "::"~PGtypeCast : "" );
    }
}

struct Fields( TL ... )
{
    @property static size_t length(){ return TL.length; }
    
    package static
    string joinFieldString( string memberName )( string delimiter )
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
    static string sql() nothrow
    {
        return joinFieldString!("sql()")(", ");
    }
    
    @disable
    package static string GenFieldsEnum() nothrow
    {
        return joinFieldString!("toDecl()")(", ");
    }
    
    //mixin("enum FieldsEnum {"~GenFieldsEnum()~"}");
}

struct QueryFields( string _name, TL ... )
{
    alias _name name; // TODO: how to write alias name this.name; in templates?
    Fields!(TL) fieldsTuples;
    alias fieldsTuples this;
    
    package static string genArrayElems() nothrow
    {
        return fieldsTuples.joinFieldString!("toArrayElement()")(", ");
    }
}

struct QueryFieldsUnity( TL ... )
{
    @property static size_t length()
    {
        size_t l = 0;
        foreach( T; TL )
            l += T.length;
            
        return l;
    }
    
    private static string genDeclArray()
    {
        string s;
        foreach( T; TL )
            s ~= T.genArrayElems()~", ";
        
        return s;
    }
    
    mixin("auto decl = ["~genDeclArray()~"];");
    
    @property
    static string sql( string name )()
    {
        foreach( T; TL )
            if( T.name == name ) return T.sql();
        
        assert( false, "Name not found" );
    }
    
    @property
    static string dollars( string name )()
    {
        size_t i = 1;
        foreach( T; TL )
        {
            if( T.name != name )
                i += T.length;
            else
                return createDollars( i, T.length );
        }
        assert( false, "Name not found" );
    }
    
    private static string createDollars( size_t start, size_t count )
    {
        size_t end = start + count;
        string r;
        foreach( i; start .. end )
        {
            r ~= "$"~to!string(i);
            if( i < end-1 ) r~=", ";
        }
        return r;
    }
}

struct ResultFields( A, TL ... )
if( is( A == Answer) || is( A == Row ) || is( A == Row* ) )
{
    Fields!(TL) fields;
    
    A answer;
    alias answer this;
    alias fields.sql sql;
    
    this( A a ) { answer = a; }
    
    invariant()
    {
        assert( answer.columnCount == TL.length );
    }
    
    static if( is( A == Answer) )
    {
        alias ResultFields!( Row, TL ) RF; // Row Fields
        
        RF opIndex( size_t rowNum )
        {
            return RF( answer[rowNum] );
        }
        
        @property RF front(){ return opIndex(answer.currRow); }
    }
    else
    {
        private auto getVal( size_t c )() { return answer.opIndex(c).as!( TL[c].type ); }    
        private static string fieldProperties( T, size_t col )()
        {
            return "@property auto getValue(string s)()"
                        "if( s == \""~T.toTemplatedName()~"\" ){ return getVal!("~to!string(col)~")(); }"
                   "@property bool isNULL(string s)()"
                        "if( s == \""~T.toTemplatedName()~"\" ){ return answer.isNULL("~to!string(col)~"); }"
                   "@property auto "~T.toDecl()~"(){ return getVal!("~to!string(col)~")(); }"
                   "@property auto "~T.toDecl()~"_isNULL(){ return answer.isNULL("~to!string(col)~"); }";
        }
        
        private static string GenProperties()
        {
            string r;
            foreach( i, T; TL )
                r ~= fieldProperties!( T, i )();
            
            return r;
        }
        
        mixin( GenProperties() );
    }
}

void _unittest( string connParam )
{
    auto conn = new Connection;
	conn.connString = connParam;
    conn.connect();
    
    alias QueryField F;    
    alias QueryFields!( "QFS1",
        F!("t1")
    ) QF;
    
    QueryFieldsUnity!( QF ) qf;
    
    alias QueryFields!( "QFS2",
        F!("t1"),
        F!("t2")
    ) QF2;
    
    QueryFieldsUnity!( QF2 ) qf2;
    
    assert( qf2.sql!("QFS2") == `"t1", "t2"` );
    assert( qf2.dollars!("QFS2") == "$1, $2" );
    assert( qf2.length == 2 );
    assert( qf.decl[0] == "t1" );
    
    alias
    ResultFields!( Row,
        ResultField!(PGtext, "t1", "", "TEXT_FIELD", "text"),
        ResultField!(PGtext, "t2")
    ) f1;
    
    alias
    ResultFields!( Row*,
        ResultField!(PGtext, "t1", "", "TEXT_FIELD", "text"),
        ResultField!(PGtext, "t2")
    ) f2;

    alias
    ResultFields!( Answer,
        ResultField!(PGtext, "t1", "", "TEXT_FIELD", "text"),
        ResultField!(PGtext, "t2")
    ) f3;
    
    queryParams p;
    p.sqlCommand = 
        "select "~f1.sql~"
         from (select '123'::integer as t1, 'qwerty'::text as t2
               union
               select '456',                'asdfgh') s
         where "~qf.sql!("QFS1")~" = "~qf.dollars!("QFS1");
         
    queryArg arg;
    arg.valueStr = "456";
    p.args = [ arg ];
    
    auto res = conn.exec( p );
        
    auto fa = f3(res);
    assert( fa[0].TEXT_FIELD == res[0][0].as!PGtext );
    assert( !fa[0].TEXT_FIELD_isNULL );
    assert( fa[0].t2 == res[0][1].as!PGtext );
    
    assert( fa[0].t2 == "asdfgh" );
    
    foreach( f; fa )
    {
        assert( f.getValue!"t2" == "asdfgh" );
        assert( f.TEXT_FIELD == "456" );
        assert( !f.isNULL!"t2" );
        assert( !f.TEXT_FIELD_isNULL );
    }
}

/*
 * Query fields can be used in this case:
 * 
		alias QueryField F;
		
		alias QueryFields!( "buildings",
			F!("district"),
			F!("microdistrict"),
			F!("street"),
			F!("house_number"),
			F!("built_at"),
			F!("floors_total"),
			F!("walls"),
			F!("development_address")
		) buildings;

		alias QueryFields!( "apartments",
			F!("apartment_type"),
			F!("floor"),
			F!("apartment_number"),
			F!("layout"),
			F!("windows_type"),
			F!("windows_orientation"),
			F!("layout_figure"),
			F!("stove"),
			F!("wc"),
			F!("balcony")
		) apartments;
		
		alias QueryFields!( "ads",
			F!("user_id"),
			F!("phone_number"),
			F!("ip"),
			F!("comment"),
			F!("contact_name"),
			F!("password")
		) ads;
		
		alias QueryFields!( "selling",
			F!("property_since"),
			F!("burden"),
			F!("percentage"),
			F!("price")
		) selling;
		
		QueryFieldsUnity!( buildings, apartments, ads, selling ) u;
		
		alias ResultField RF;
		alias ResultFields!( Row,
			RF!(PGtext, "uniq_random_id")
		) RFS;
		
		queryParams p;
		p.sqlCommand = "
			with b as (
				insert into apartments.buildings("~u.sql!("buildings")~")
				values("~u.dollars!("buildings")~")
				returning building_id
			),
			
			ap as (
				insert into apartments.apartments(building_id, "~u.sql!("apartments")~")
				values((select building_id from b), "~u.dollars!("apartments")~")
				returning apartment_id
			),
			
			ads as (
				insert into ads.ads(apartment_id, "~u.sql!("ads")~")
				values((select apartment_id from ap), "~u.dollars!("ads")~")
				returning ads_id, uniq_random_id
			),
			
			s as (
				insert into ads.selling(ads_id, "~u.sql!("selling")~")
				values((select ads_id from ads), "~u.dollars!("selling")~")
			)
			
			select "~RFS.sql~" from ads"; // (Illegal use of QueryFields)
*/
