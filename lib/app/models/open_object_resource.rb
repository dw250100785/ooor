require 'xmlrpc/client'
require 'activeresource'

class OpenObjectResource < ActiveResource::Base

  # ******************** class methods ********************
  class << self

    cattr_accessor :logger
    attr_accessor :openerp_id, :info, :access_ids, :name, :openerp_model, :field_ids, :state, #model class attributes assotiated to the OpenERP ir.model
                  :field_defined, :many2one_relations, :one2many_relations, :many2many_relations,
                  :openerp_database, :user_id

    def class_name_from_model_key(model_key)
      model_key.split('.').collect {|name_part| name_part[0..0].upcase + name_part[1..-1]}.join
    end

    def reload_fields_definition(force = false)
      if self != IrModel and self != IrModelFields and (force or not @field_defined)#TODO have a way to force reloading @field_ids too eventually
        fields = IrModelFields.find(@field_ids)
        @fields = {}
        @many2one_relations = {}
        @one2many_relations = {}
        @many2many_relations = {}
        fields.each do |field|
          case field.attributes['ttype']
          when 'many2one'
            @many2one_relations[field.attributes['name']] = field
          when 'one2many'
            @one2many_relations[field.attributes['name']] = field
          when 'many2many'
            @many2many_relations[field.attributes['name']] = field
          else
            @fields[field.attributes['name']] = field
          end
        end
        logger.info "#{fields.size} fields loaded"
      end
      @field_defined = true
    end

    def define_openerp_model(arg, url, database, user_id, pass, binding)
      param = (arg.is_a? OpenObjectResource) ? arg.attributes.merge(arg.relations) : {'model' => arg}
      model_key = param['model']
      Ooor.all_loaded_models.push(model_key)
      model_class_name = class_name_from_model_key(model_key)
      logger.info "registering #{model_class_name} as a Rails ActiveResource Model wrapper for OpenObject #{model_key} model"
      definition = "
      class #{model_class_name} < OpenObjectResource
        self.site = '#{url || Ooor.object_url}'
        self.user = #{user_id}
        self.password = #{pass || false}
        self.openerp_database = '#{database}'
        self.openerp_model = '#{model_key}'
        self.openerp_id = #{param['id'] || false}
        self.info = '#{(param['info'] || '').gsub("'",' ')}'
        self.name = '#{param['name']}'
        self.state = '#{param['state']}'
        self.field_ids = #{(param['field_id'] and '[' + param['field_id'].join(',') + ']') || false}
        self.access_ids = #{(param['access_ids'] and '[' + param['access_ids'].join(',') + ']') || false}
        self.many2one_relations = {}
        self.one2many_relations = {}
        self.many2many_relations = {}
      end"
      eval definition, binding
    end


    # ******************** remote communication ********************

    #OpenERP search method
    def search(domain, offset=0, limit=false, order=false, context={}, count=false)
      rpc_execute('search', domain, offset, limit, order, context, count)
    end

    def client(url)
      @clients ||= {}
      @client = @clients[url]
      unless @clientl
        @client ||= XMLRPC::Client.new2(url)
        @clients[url] = @client
      end
      return @client
    end

    #corresponding method for OpenERP osv.execute(self, db, uid, obj, method, *args, **kw) method
    def rpc_execute(method, *args)
      rpc_execute_with_object(@openerp_model, method, *args)
    end

    def rpc_execute_with_object(object, method, *args)
      rpc_execute_with_all(@database || Ooor.config[:database], @user_id || Ooor.config[:user_id], @password || Ooor.config[:password], object, method, *args)
    end

    #corresponding method for OpenERP osv.execute(self, db, uid, obj, method, *args, **kw) method
    def rpc_execute_with_all(db, uid, pass, obj, method, *args)
      try_with_pretty_error_log { client(@database && @site || Ooor.object_url).call("execute",  db, uid, pass, obj, method, *args) }
    end

     #corresponding method for OpenERP osv.exec_workflow(self, db, uid, obj, method, *args)
    def rpc_exec_workflow(method, *args)
      rpc_exec_workflow_with_object(@openerp_model, method, *args)
    end

    def rpc_exec_workflow_with_object(object, method, *args)
      rpc_exec_workflow_with_all(@database || Ooor.config[:database], @user_id || Ooor.config[:user_id], @password || Ooor.config[:password], object, method, *args)
    end

    def rpc_exec_workflow_with_all(method, *args)
      try_with_pretty_error_log { client(@database && @site || Ooor.object_url).call("exec_workflow", method, *args) }
    end

    #grab the eventual error log from OpenERP response as OpenERP doesn't enforce carefuly
    #the XML/RPC spec, see https://bugs.launchpad.net/openerp/+bug/257581
    def try_with_pretty_error_log
        yield
      rescue RuntimeError => e
        begin
          openerp_error_hash = eval("#{ e }".gsub("wrong fault-structure: ", ""))
          if openerp_error_hash.is_a? Hash
            logger.error "*********** OpenERP Server ERROR:
            #{openerp_error_hash["faultString"]}
            ***********"
          end
        rescue
        end
        raise
    end

    def load_relation(model_key, ids, *arguments)
      options = arguments.extract_options!
      unless Ooor.all_loaded_models.index(model_key)
        model = IrModel.find(:first, :domain => [['model', '=', model_key]])
        define_openerp_model(model, nil, nil, nil, nil, Ooor.binding)
      end
      relation_model_class = eval class_name_from_model_key(model_key)
      relation_model_class.send :find, ids, :fields => options[:fields] || [], :context => options[:context] || {}
    end


    # ******************** finders low level implementation ********************

    private

    def find_every(options)
      domain = options[:domain]
      context = options[:context] || {}
      unless domain
        prefix_options, query_options = split_options(options[:params])
        domain = []
        query_options.each_pair do |k, v|
          domain.push [k.to_s, '=', v]
        end
      end
      ids = rpc_execute('search', domain, context)
      find_single(ids, options)
    end

    #TODO, make sense?
    def find_one
      raise "Not implemented yet, go one!"
    end

    # Find a single resource from the default URL
    def find_single(scope, options)
      fields = (options[:fields] and [options[:fields]]) || []
      context = options[:context] || {}
      prefix_options, query_options = split_options(options[:params])
      is_collection = true
      if !scope.is_a? Array
        scope = [scope]
        is_collection = false
      end
      records = rpc_execute('read', scope, *(fields + [context]))
      active_resources = []
      records.each do |record|
        r = {}
        record.each_pair do |k,v|
          r[k.to_sym] = v
        end
        active_resources << instantiate_record(r, prefix_options)
      end
      unless is_collection
        return active_resources[0]
      end
      return active_resources
    end

  end


  # ******************** instance methods ********************

  attr_accessor :ooor_user, :ooor_password

  def pre_cast_attributes
    @attributes.each {|k, v| @attributes[k] = ((v.is_a? BigDecimal) ? Float(v) : v)}
  end

  def load(attributes)
    self.class.reload_fields_definition unless self.class.field_defined
    raise ArgumentError, "expected an attributes Hash, got #{attributes.inspect}" unless attributes.is_a?(Hash)
    @prefix_options, attributes = split_options(attributes)
    attributes.each do |key, value|
      case value
        when Array
           relations[key.to_s] = value #the relation because we want the method to load the association through method missing
        when Hash
          resource = find_or_create_resource_for(key) #TODO check!
          @attributes[key.to_s] = resource@attributes[key.to_s].new(value)
        else
          @attributes[key.to_s] = value.dup rescue value
      end
    end

    self
  end

  #compatible with the Rails way but also supports OpenERP context
  def create(context={})
    self.pre_cast_attributes
    self.id = self.class.rpc_execute('create', @attributes, context)
    load(self.class.find(self.id, :context => context).attributes)
  end

  #compatible with the Rails way but also supports OpenERP context
  def update(context={})
    self.pre_cast_attributes
    self.class.rpc_execute('write', self.id, @attributes.reject{|k, v| k == 'id'}, context)
    load(self.class.find(self.id, :context => context).attributes)
  end

  #compatible with the Rails way but also supports OpenERP context
  def destroy(context={})
    self.class.rpc_execute('unlink', self.id, context)
  end

  #OpenERP copy method, load persisted copied Object
  def copy(defaults=[], context={})
    self.class.find(self.class.rpc_execute('copy', self.id, defaults, context), :context => context)
  end

  #Generic OpenERP rpc method call
  def call(method, *args)
    self.class.rpc_execute(method, *args)
  end

  #Generic OpenERP on_change method
  def on_change(on_change_method, *args)
    result = self.class.rpc_execute(on_change_method, *args)
    session
    self.classlogger.info result["warning"]["title"] if result["warning"]
    self.class.logger.info result["warning"]["message"] if result["warning"]
    load(result["value"])
  end


  # ******************** fake associations like much like ActiveRecord according to the cached OpenERP data model ********************

  def relations
    @relations ||= {} and @relations
  end

  def relationnal_result(method_id, *arguments)
    self.class.reload_fields_definition unless self.class.field_defined
    if self.class.many2one_relations[method_id.to_s]
      self.class.load_relation(self.class.many2one_relations[method_id.to_s].relation, @relations[method_id.to_s][0], *arguments)
    elsif self.class.one2many_relations[method_id.to_s]
      self.class.load_relation(self.class.one2many_relations[method_id.to_s].relation, @relations[method_id.to_s], *arguments)
    elsif self.class.many2many_relations[method_id.to_s]
      self.class.load_relation(self.class.many2many_relations[method_id.to_s].relation, @relations[method_id.to_s], *arguments)
    else
      false
    end
  end

  def method_missing(method_id, *arguments)
    @loaded_relations ||= {}
    result = @loaded_relations[method_id.to_s]
    return result if result
    result = relationnal_result(method_id, *arguments)
    if result
      @loaded_relations[method_id.to_s] = result
      return result 
    elsif @relations and @relations[method_id.to_s] and !self.class.many2one_relations.empty?
      #maybe the relation is inherited or could be inferred from a related field
      self.class.many2one_relations.each do |k, field|
        model = self.class.load_relation(field.relation, @relations[method_id.to_s][0], *arguments)
        result = model.relationnal_result(method_id, *arguments)
        return result if result
      end
      super
    end
    super
  end

end